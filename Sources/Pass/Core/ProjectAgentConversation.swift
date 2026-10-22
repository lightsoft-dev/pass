import Foundation
import Observation

struct ProjectAgentMessage: Identifiable {
    enum Role { case user, assistant, activity, error }
    let id = UUID()
    let role: Role
    var text: String
    var attachments: [URL] = []
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
    private(set) var manuallySelectedModel: String?
    private(set) var availableModels: [PiModelOption] = []

    var selectableModels: [PiModelOption] {
        let providers = PiAuthentication.usableProviders()
        return availableModels.filter { providers.contains($0.provider) }
    }

    var canChangeModel: Bool { isReady && !isResponding && !settingModel && !waitingForModels }
    var canSendMessage: Bool { isReady && !isResponding && !settingModel }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: Pipe?
    @ObservationIgnored private var output: Pipe?
    @ObservationIgnored private var errorOutput: Pipe?
    @ObservationIgnored private var lineBuffer = Data()
    @ObservationIgnored private var stderrTail = ""
    @ObservationIgnored private var assistantID: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var activePrompt: String?
    @ObservationIgnored private var activeImages: [[String: Any]] = []
    @ObservationIgnored private var toolStartedForPrompt = false
    @ObservationIgnored private var attemptedModels: Set<String> = []
    @ObservationIgnored private var blockedProviders: Set<String> = []
    @ObservationIgnored private var retryError: String?
    @ObservationIgnored private var waitingForModels = false
    @ObservationIgnored private var waitingForAgentEnd = false
    @ObservationIgnored private var settingModel = false
    @ObservationIgnored private var pendingModel: PiModelOption?
    @ObservationIgnored private var pendingSelectionIsManual = false
    @ObservationIgnored private var restartWhenIdle = false

    init(projectRoot: String) {
        self.projectRoot = projectRoot
        manuallySelectedModel = UserDefaults.standard.string(forKey:
            "projectAgent.manualModel." + ProjectAgentIdentity.sessionName(for: projectRoot))
    }

    func start() {
        guard !started else { return }
        started = true
        launch()
    }

    func restartAfterPiUpdate() {
        guard started else { return }
        if isResponding {
            restartWhenIdle = true
            return
        }
        generation += 1
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        input?.fileHandleForWriting.closeFile()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        lineBuffer.removeAll()
        stderrTail = ""
        availableModels = []
        assistantID = nil
        retryError = nil
        activeImages = []
        waitingForModels = false
        waitingForAgentEnd = false
        settingModel = false
        pendingModel = nil
        isReady = false
        status = "새 Pi 버전으로 다시 연결하는 중…"
        restartWhenIdle = false
        launch()
    }

    @discardableResult
    func send(_ text: String, files: [URL] = []) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendMessage, !body.isEmpty || !files.isEmpty else { return false }
        let storedFiles: [URL]
        let images: [[String: Any]]
        do {
            storedFiles = try ProjectAgentAttachments.copyFiles(files, for: projectRoot)
            do { images = try ProjectAgentAttachments.imagePayloads(for: storedFiles) }
            catch {
                for file in storedFiles { try? FileManager.default.removeItem(at: file) }
                throw error
            }
        } catch {
            messages.append(ProjectAgentMessage(role: .error, text: error.localizedDescription))
            status = "파일을 첨부할 수 없습니다"
            return false
        }
        let prompt = ProjectAgentAttachments.prompt(body, files: storedFiles)
        let entry = ProjectAgentMessage(role: .user, text: body.isEmpty ? "첨부 파일을 확인해 주세요." : body,
                                        attachments: storedFiles)
        messages.append(entry)
        isResponding = true
        activePrompt = prompt
        activeImages = images
        toolStartedForPrompt = false
        attemptedModels = [modelLabel]
        blockedProviders = []
        retryError = nil
        waitingForAgentEnd = false
        modelError = false
        status = "생각하는 중…"
        if !sendPrompt(prompt, images: images) {
            messages.append(ProjectAgentMessage(role: .error, text: "메시지를 보낼 수 없습니다. 에이전트를 다시 열어 주세요."))
            isResponding = false
            activePrompt = nil
            activeImages = []
            return false
        }
        return true
    }

    private func sendPrompt(_ body: String, images: [[String: Any]]) -> Bool {
        var command: [String: Any] = ["id": UUID().uuidString, "type": "prompt", "message": body,
                                      "streamingBehavior": "followUp"]
        if !images.isEmpty { command["images"] = images }
        return write(command)
    }

    private var modelPreferenceKey: String {
        "projectAgent.model." + ProjectAgentIdentity.sessionName(for: projectRoot)
    }

    private var manualModelKey: String {
        "projectAgent.manualModel." + ProjectAgentIdentity.sessionName(for: projectRoot)
    }

    func selectModel(_ model: PiModelOption) {
        guard canChangeModel, selectableModels.contains(model) else { return }
        if model.label == modelLabel {
            saveManualSelection(model.label)
            return
        }
        pendingModel = model
        pendingSelectionIsManual = true
        settingModel = true
        status = "\(model.label) 연결 중…"
        if !write(["id": "manual-model", "type": "set_model",
                   "provider": model.provider, "modelId": model.id]) {
            settingModel = false
            pendingModel = nil
            status = "모델을 바꿀 수 없습니다"
        }
    }

    func useAutomaticModel() {
        guard canChangeModel else { return }
        let preferred = preferredAutomaticModel()
        guard let preferred, preferred != modelLabel,
              let model = selectableModels.first(where: { $0.label == preferred }) else {
            saveManualSelection(nil)
            return
        }
        pendingModel = model
        pendingSelectionIsManual = false
        settingModel = true
        status = "\(model.label) 연결 중…"
        if !write(["id": "manual-model", "type": "set_model",
                   "provider": model.provider, "modelId": model.id]) {
            settingModel = false
            pendingModel = nil
            status = "모델을 바꿀 수 없습니다"
        }
    }

    private func saveManualSelection(_ label: String?) {
        manuallySelectedModel = label
        if let label {
            UserDefaults.standard.set(label, forKey: manualModelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: manualModelKey)
        }
    }

    private static let lastWorkingModelKey = "projectAgent.lastWorkingModel"
    private static let unsupportedModelsKey = "projectAgent.unsupportedModels"

    private func savedModelChoices() -> [String] {
        let defaults = UserDefaults.standard
        var choices: [String] = []
        if let model = defaults.string(forKey: modelPreferenceKey) { choices.append(model) }
        if let model = defaults.string(forKey: Self.lastWorkingModelKey) { choices.append(model) }
        for key in defaults.dictionaryRepresentation().keys.sorted()
            where key.hasPrefix("projectAgent.model.") && key != modelPreferenceKey {
            if let model = defaults.string(forKey: key) { choices.append(model) }
        }
        var seen: Set<String> = []
        return choices.filter { seen.insert($0).inserted }
    }

    private func preferredModelOnLaunch() -> String? {
        if let manuallySelectedModel {
            if let provider = manuallySelectedModel.split(separator: "/", maxSplits: 1).first,
               PiAuthentication.hasCredential(for: String(provider)) {
                return manuallySelectedModel
            }
            saveManualSelection(nil)
        }
        return preferredAutomaticModel()
    }

    private func preferredAutomaticModel() -> String? {
        let unsupported = Set(UserDefaults.standard.stringArray(forKey: Self.unsupportedModelsKey) ?? [])
        for choice in savedModelChoices() where !unsupported.contains(choice) {
            if let provider = choice.split(separator: "/", maxSplits: 1).first,
               PiAuthentication.hasCredential(for: String(provider)) {
                return choice
            }
        }
        return nil
    }

    private func rememberUnsupportedModel() {
        var models = Set(UserDefaults.standard.stringArray(forKey: Self.unsupportedModelsKey) ?? [])
        models.insert(modelLabel)
        UserDefaults.standard.set(models.sorted(), forKey: Self.unsupportedModelsKey)
    }

    private func launch() {
        guard let pi = Shell.resolveViaLoginShell("pi"),
              let instructions = Bundle.main.path(forResource: "ProjectAgentInstructions", ofType: "md") else {
            status = "Pi를 찾을 수 없습니다. Pi를 설치한 뒤 Pass를 다시 열어 주세요."
            return
        }
        let memory: URL
        do {
            memory = try ProjectAgentWorkerMemory.ensureFile(for: projectRoot)
        } catch {
            status = "Pa 워커 메모리를 열 수 없습니다: \(error.localizedDescription)"
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
                             "--append-system-prompt", instructions,
                             "--append-system-prompt", memory.path]
        if let selectedModel = preferredModelOnLaunch(),
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
        environment["PASS_PA_MEMORY"] = memory.path
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
            waitingForModels = write(["id": "models", "type": "get_available_models"])
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
            let id = event["id"] as? String ?? ""
            if id == "history" {
                if let data = event["data"] as? [String: Any],
                   let history = data["messages"] as? [[String: Any]] {
                    messages = Self.messagesFromHistory(history)
                }
                isReady = event["success"] as? Bool == true
                status = isReady ? "준비됨" : (event["error"] as? String ?? "대화를 불러올 수 없습니다.")
            } else if id == "models" {
                waitingForModels = false
                if let data = event["data"] as? [String: Any],
                   let models = data["models"] as? [[String: Any]] {
                    availableModels = models.compactMap(PiModelOption.init)
                }
                if retryError != nil && !waitingForAgentEnd { tryNextModel() }
            } else if id == "auto-model" {
                settingModel = false
                if event["success"] as? Bool == true, let selected = pendingModel,
                   let prompt = activePrompt {
                    modelLabel = selected.label
                    pendingModel = nil
                    retryError = nil
                    status = "\(modelLabel)로 다시 시도하는 중…"
                    if !sendPrompt(prompt, images: activeImages) {
                        finishModelFailure("Pa가 요청을 다시 보낼 수 없습니다.")
                    }
                } else {
                    pendingModel = nil
                    tryNextModel()
                }
            } else if id == "manual-model" {
                settingModel = false
                if event["success"] as? Bool == true, let selected = pendingModel {
                    modelLabel = selected.label
                    modelError = false
                    saveManualSelection(pendingSelectionIsManual ? selected.label : nil)
                    status = "준비됨"
                } else {
                    status = "모델을 바꿀 수 없습니다"
                    let error = event["error"] as? String ?? "선택한 모델을 사용할 수 없습니다."
                    messages.append(ProjectAgentMessage(role: .error, text: Self.readableError(error)))
                }
                pendingModel = nil
            } else if event["success"] as? Bool == false {
                let error = event["error"] as? String ?? "Pi 요청이 실패했습니다."
                if !handleModelFailure(error) {
                    messages.append(ProjectAgentMessage(role: .error, text: Self.readableError(error)))
                    isResponding = false
                    activePrompt = nil
                    activeImages = []
                    status = "응답 오류"
                } else {
                    tryNextModel()
                }
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
            let completedAssistantID = assistantID
            if let assistantID, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[index].text = text
                if type == "message_end", text.isEmpty { messages.remove(at: index) }
            }
            if type == "message_end" {
                assistantID = nil
                if let error = message["errorMessage"] as? String {
                    if handleModelFailure(error, waitForAgentEnd: true) {
                        if let completedAssistantID {
                            messages.removeAll { $0.id == completedAssistantID }
                        }
                    } else {
                        messages.append(ProjectAgentMessage(role: .error,
                                                            text: Self.readableError(error)))
                        activePrompt = nil
                        activeImages = []
                        status = "응답 오류"
                    }
                }
            }
        case "tool_execution_start":
            toolStartedForPrompt = true
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
            if event["willRetry"] as? Bool == true { return }
            if retryError != nil {
                waitingForAgentEnd = false
                tryNextModel()
            } else {
                if activePrompt != nil && !modelError {
                    UserDefaults.standard.set(modelLabel, forKey: modelPreferenceKey)
                    UserDefaults.standard.set(modelLabel, forKey: Self.lastWorkingModelKey)
                }
                activePrompt = nil
                activeImages = []
                isResponding = false
                if !modelError { status = "준비됨" }
                if restartWhenIdle { restartAfterPiUpdate() }
            }
        default: break
        }
    }

    private func handleModelFailure(_ error: String, waitForAgentEnd: Bool = false) -> Bool {
        guard activePrompt != nil, !toolStartedForPrompt,
              Self.isRecoverableModelError(error) else { return false }
        if manuallySelectedModel == modelLabel { saveManualSelection(nil) }
        if error.localizedCaseInsensitiveContains("model is not supported") {
            rememberUnsupportedModel()
        }
        if error.localizedCaseInsensitiveContains("when using Codex with a ChatGPT account"),
           let provider = modelLabel.split(separator: "/", maxSplits: 1).first {
            blockedProviders.insert(String(provider))
        }
        retryError = error
        waitingForAgentEnd = waitForAgentEnd
        status = "사용 가능한 모델을 찾는 중…"
        return true
    }

    private func tryNextModel() {
        guard let retryError, activePrompt != nil, !settingModel,
              !waitingForAgentEnd else { return }
        if waitingForModels { return }
        guard attemptedModels.count < 4 else { finishModelFailure(retryError); return }
        let candidates = PiModelSelection.candidates(
            availableModels,
            usableProviders: PiAuthentication.usableProviders(),
            preferredLabels: savedModelChoices(),
            attemptedLabels: attemptedModels,
            blockedProviders: blockedProviders)
        guard let next = candidates.first else { finishModelFailure(retryError); return }
        attemptedModels.insert(next.label)
        pendingModel = next
        settingModel = true
        status = "\(next.label) 연결 중…"
        if !write(["id": "auto-model", "type": "set_model",
                   "provider": next.provider, "modelId": next.id]) {
            settingModel = false
            pendingModel = nil
            tryNextModel()
        }
    }

    private func finishModelFailure(_ error: String) {
        retryError = nil
        waitingForAgentEnd = false
        pendingModel = nil
        settingModel = false
        activePrompt = nil
        activeImages = []
        isResponding = false
        modelError = true
        status = "모델에 연결할 수 없습니다"
        messages.append(ProjectAgentMessage(role: .error,
            text: Self.readableError(error) + " Pi 계정을 연결하거나 모델 설정을 확인해 주세요."))
        if restartWhenIdle { restartAfterPiUpdate() }
    }

    private static func isRecoverableModelError(_ error: String) -> Bool {
        let lower = error.lowercased()
        return lower.contains("model is not supported")
            || lower.contains("no api key for provider")
            || lower.contains("authentication failed")
            || lower.contains("oauth token")
            || lower.contains("invalid api key")
            || lower.contains("unauthorized")
            || lower.contains("rate limit")
            || lower.contains("429")
    }

    private static func textContent(_ message: [String: Any]) -> String {
        let content = message["content"] as? [[String: Any]] ?? []
        return content.compactMap { part in
            part["type"] as? String == "text" ? part["text"] as? String : nil
        }.joined(separator: "\n")
    }

    private static func messageFromHistory(_ message: [String: Any]) -> ProjectAgentMessage? {
        guard let role = message["role"] as? String else { return nil }
        if role == "user" {
            let display = ProjectAgentAttachments.displayContent(textContent(message))
            return ProjectAgentMessage(role: .user, text: display.text, attachments: display.files)
        }
        if role == "assistant" {
            let text = textContent(message)
            if !text.isEmpty { return ProjectAgentMessage(role: .assistant, text: text) }
            if let error = message["errorMessage"] as? String {
                return ProjectAgentMessage(role: .error, text: readableError(error))
            }
        }
        return nil
    }

    private static func messagesFromHistory(_ history: [[String: Any]]) -> [ProjectAgentMessage] {
        var visible: [ProjectAgentMessage] = []
        var index = 0
        while index < history.count {
            if index + 2 < history.count,
               history[index]["role"] as? String == "user",
               history[index + 1]["role"] as? String == "assistant",
               let error = history[index + 1]["errorMessage"] as? String,
               isRecoverableModelError(error),
               history[index + 2]["role"] as? String == "user",
               textContent(history[index]) == textContent(history[index + 2]) {
                index += 2
                continue
            }
            if let message = messageFromHistory(history[index]) { visible.append(message) }
            index += 1
        }
        return visible
    }

    private static func readableError(_ error: String) -> String {
        if error.localizedCaseInsensitiveContains("model is not supported") {
            return "현재 계정에서는 선택된 Pi 모델을 사용할 수 없습니다."
        }
        return error
    }
}

struct PiModelOption: Equatable {
    let provider: String
    let id: String
    var label: String { provider + "/" + id }

    init(provider: String, id: String) {
        self.provider = provider
        self.id = id
    }

    init?(_ data: [String: Any]) {
        guard let provider = data["provider"] as? String,
              let id = data["id"] as? String,
              let inputs = data["input"] as? [String], inputs.contains("text")
        else { return nil }
        self.init(provider: provider, id: id)
    }
}

enum PiModelSelection {
    static func candidates(_ models: [PiModelOption], usableProviders: Set<String>,
                           preferredLabels: [String], attemptedLabels: Set<String>,
                           blockedProviders: Set<String>) -> [PiModelOption] {
        let eligible = models.filter {
            usableProviders.contains($0.provider)
                && !attemptedLabels.contains($0.label)
                && !blockedProviders.contains($0.provider)
        }
        var ordered: [PiModelOption] = []
        for label in preferredLabels {
            if let model = eligible.first(where: { $0.label == label }), !ordered.contains(model) {
                ordered.append(model)
            }
        }
        for provider in Set(eligible.map(\.provider)).sorted() {
            if let model = eligible.first(where: { $0.provider == provider }),
               !ordered.contains(model) {
                ordered.append(model)
            }
        }
        for model in eligible where !ordered.contains(model) { ordered.append(model) }
        return ordered
    }
}
