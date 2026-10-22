import Foundation
import Observation

struct ProjectAgentMessage: Identifiable {
    enum Role { case user, assistant, activity, error }
    let id = UUID()
    let role: Role
    var text: String
}

/// Runs Pi as a headless conversation engine. Pass owns the chat UI; stdout is JSONL RPC,
/// never terminal escape sequences. One instance is retained per project by AppModel.
@MainActor
@Observable
final class ProjectAgentConversation {
    let projectRoot: String
    private(set) var messages: [ProjectAgentMessage] = []
    private(set) var isReady = false
    private(set) var isResponding = false
    private(set) var status = "에이전트를 시작하는 중…"
    private(set) var modelLabel = "Pi 기본 모델"
    private(set) var modelError = false

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: Pipe?
    @ObservationIgnored private var output: Pipe?
    @ObservationIgnored private var errorOutput: Pipe?
    @ObservationIgnored private var lineBuffer = Data()
    @ObservationIgnored private var stderrTail = ""
    @ObservationIgnored private var assistantID: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = 0

    init(projectRoot: String) { self.projectRoot = projectRoot }

    func start() {
        guard !started else { return }
        started = true
        launch()
    }

    func useWorkingModel() {
        guard PiAuthentication.hasCredential(for: "zai") else { return }
        UserDefaults.standard.set("zai/glm-4.7", forKey: modelPreferenceKey)
        restart()
    }

    var canUseWorkingModel: Bool {
        modelError && PiAuthentication.hasCredential(for: "zai") && modelLabel != "zai/glm-4.7"
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, !body.isEmpty else { return false }
        let entry = ProjectAgentMessage(role: .user, text: body)
        messages.append(entry)
        isResponding = true
        status = "생각하는 중…"
        if !write(["id": UUID().uuidString, "type": "prompt", "message": body,
                   "streamingBehavior": "followUp"]) {
            messages.append(ProjectAgentMessage(role: .error, text: "메시지를 보낼 수 없습니다. 에이전트를 다시 열어 주세요."))
            isResponding = false
            return false
        }
        return true
    }

    private var modelPreferenceKey: String {
        "projectAgent.model." + ProjectAgentIdentity.sessionName(for: projectRoot)
    }

    private func restart() {
        generation += 1
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        input?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        isReady = false
        isResponding = false
        modelError = false
        lineBuffer.removeAll()
        launch()
    }

    private func launch() {
        guard let pi = Shell.resolveViaLoginShell("pi"),
              let instructions = Bundle.main.path(forResource: "ProjectAgentInstructions", ofType: "md") else {
            status = "Pi를 찾을 수 없습니다. Pi를 설치한 뒤 Pass를 다시 열어 주세요."
            return
        }
        let generation = self.generation
        let process = Process()
        let input = Pipe(), output = Pipe(), errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: pi)
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.arguments = ["--no-extensions", "--mode", "rpc", "--session-id",
                             ProjectAgentIdentity.rpcSessionID(for: projectRoot),
                             "--name", URL(fileURLWithPath: projectRoot).lastPathComponent + " · Pa",
                             "--append-system-prompt", instructions]
        if let selectedModel = UserDefaults.standard.string(forKey: modelPreferenceKey),
           let slash = selectedModel.firstIndex(of: "/") {
            process.arguments! += ["--provider", String(selectedModel[..<slash]),
                                   "--model", String(selectedModel[selectedModel.index(after: slash)...])]
            modelLabel = selectedModel
        } else {
            modelLabel = PiAuthentication.defaultModelLabel() ?? "Pi 기본 모델"
        }
        var environment = ProcessInfo.processInfo.environment
        environment[PassConfig.sessionEnvVar] = ProjectAgentIdentity.sessionName(for: projectRoot)
        environment[PassConfig.cliEnvVar] = CLIInstaller.bundledBinaryPath ?? PassConfig.cliSymlinkPath
        environment["PATH"] = URL(fileURLWithPath: pi).deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.consume(data)
            }
        }
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(2_000))
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.isReady = false
                self.isResponding = false
                self.status = "Pi 연결이 종료되었습니다 (코드 \(process.terminationStatus))."
                if !self.stderrTail.isEmpty {
                    self.messages.append(ProjectAgentMessage(role: .error,
                        text: "Pi 연결이 종료되었습니다. 계정 연결과 모델 설정을 확인해 주세요."))
                }
            }
        }
        do {
            try process.run()
            self.process = process
            self.input = input
            self.output = output
            self.errorOutput = errorOutput
            status = "이전 대화를 불러오는 중…"
            _ = write(["id": "history", "type": "get_messages"])
        } catch {
            status = "Pi를 시작할 수 없습니다: \(error.localizedDescription)"
            messages.append(ProjectAgentMessage(role: .error, text: status))
        }
    }

    private func write(_ command: [String: Any]) -> Bool {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: command) else { return false }
        do {
            try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
            return true
        } catch { return false }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 10) {
            let line = Data(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            receive(event)
        }
    }

    private func receive(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        if type == "response" {
            if event["id"] as? String == "history" {
                if let data = event["data"] as? [String: Any],
                   let history = data["messages"] as? [[String: Any]] {
                    messages = history.compactMap(Self.messageFromHistory)
                }
                isReady = event["success"] as? Bool == true
                status = isReady ? "준비됨" : (event["error"] as? String ?? "대화를 불러올 수 없습니다.")
            } else if event["success"] as? Bool == false {
                let error = event["error"] as? String ?? "Pi 요청이 실패했습니다."
                messages.append(ProjectAgentMessage(role: .error, text: error))
                isResponding = false
                status = error
            }
            return
        }
        switch type {
        case "message_start":
            if let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" {
                let entry = ProjectAgentMessage(role: .assistant, text: "")
                assistantID = entry.id
                messages.append(entry)
            }
        case "message_update", "message_end":
            guard let message = event["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { return }
            let text = Self.textContent(message)
            if let assistantID, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[index].text = text
                if type == "message_end", text.isEmpty { messages.remove(at: index) }
            }
            if type == "message_end" {
                assistantID = nil
                if let error = message["errorMessage"] as? String {
                    modelError = error.localizedCaseInsensitiveContains("model is not supported")
                    messages.append(ProjectAgentMessage(role: .error,
                                                        text: Self.readableError(error)))
                    status = modelError ? "모델 연결 오류" : "응답 오류"
                }
            }
        case "tool_execution_start":
            let name = event["toolName"] as? String ?? "도구"
            status = "\(name) 실행 중…"
            messages.append(ProjectAgentMessage(role: .activity, text: "\(name) 실행 중…"))
        case "tool_execution_end":
            let name = event["toolName"] as? String ?? "도구"
            let result = event["result"] as? [String: Any] ?? [:]
            let text = Self.textContent(result)
            let preview = String(text.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ProjectAgentMessage(role: .activity,
                                                 text: preview.isEmpty ? "\(name) 완료" : "\(name) 완료\n\(preview)"))
            status = "결과를 정리하는 중…"
        case "agent_end":
            isResponding = false
            if !modelError { status = "준비됨" }
        default: break
        }
    }

    private static func textContent(_ message: [String: Any]) -> String {
        let content = message["content"] as? [[String: Any]] ?? []
        return content.compactMap { part in
            part["type"] as? String == "text" ? part["text"] as? String : nil
        }.joined(separator: "\n")
    }

    private static func messageFromHistory(_ message: [String: Any]) -> ProjectAgentMessage? {
        guard let role = message["role"] as? String else { return nil }
        if role == "user" { return ProjectAgentMessage(role: .user, text: textContent(message)) }
        if role == "assistant" {
            let text = textContent(message)
            if !text.isEmpty { return ProjectAgentMessage(role: .assistant, text: text) }
            if let error = message["errorMessage"] as? String {
                return ProjectAgentMessage(role: .error, text: readableError(error))
            }
        }
        return nil
    }

    private static func readableError(_ error: String) -> String {
        if error.localizedCaseInsensitiveContains("model is not supported") {
            return "현재 ChatGPT 계정에서는 선택된 Pi 모델을 사용할 수 없습니다. 연결된 다른 모델을 선택해 주세요."
        }
        return error
    }
}
