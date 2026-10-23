import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A project's Pi coordinator with worker terminals revealed only on request.
struct ProjectAgentView: View {
    let projectRoot: String
    let sessions: [Session]
    let initialDraft: String
    let focusToken: Int
    let onBack: () -> Void
    let onOpenWorker: (String) -> Void

    @Environment(AppModel.self) private var appModel
    @State private var selectedWorkerName: String?
    @State private var message = ""
    @State private var attachedFiles: [URL] = []
    @State private var isDropTargeted = false
    @State private var status: String?
    @State private var pendingLoginMessage: String?
    @State private var conversation: ProjectAgentConversation?
    @FocusState private var messageFocused: Bool

    private var projectName: String { URL(fileURLWithPath: projectRoot).lastPathComponent }
    private var workers: [Session] {
        sessions.filter { $0.projectRoot == projectRoot && !$0.isProjectAgent }
    }
    private var selectedWorker: Session? {
        workers.first { $0.name == selectedWorkerName }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                if geometry.size.width >= 850 {
                    HStack(spacing: 0) {
                        managerPane.frame(maxWidth: .infinity)
                        Divider()
                        workerPane.frame(width: selectedWorker == nil
                                         ? min(max(geometry.size.width * 0.28, 220), 300)
                                         : min(max(geometry.size.width * 0.42, 360), 560))
                    }
                } else {
                    VStack(spacing: 0) {
                        managerPane.frame(maxHeight: .infinity)
                        Divider()
                        workerPane.frame(height: selectedWorker == nil
                                         ? min(max(geometry.size.height * 0.20, 130), 180)
                                         : min(max(geometry.size.height * 0.45, 250), 420))
                    }
                }
            }
        }
        .task(id: projectRoot) {
            conversation = nil
            message = initialDraft
            attachedFiles = []
            pendingLoginMessage = nil
            let agent = appModel.projectAgentConversation(for: projectRoot)
            conversation = agent
            agent.start()
            if PiAuthentication.needsLogin() {
                status = "Pi 로그인이 필요합니다. 열린 작은 터미널에서 계정을 연결하세요."
                appModel.miniTerminals.openPiLogin()
            } else {
                status = nil
            }
        }
        .onChange(of: focusToken, initial: true) { _, _ in
            messageFocused = false
            DispatchQueue.main.async { messageFocused = true }
        }
        .task(id: projectRoot) {
            while !Task.isCancelled {
                if !PiAuthentication.needsLogin() {
                    if status?.contains("로그인") == true { status = nil }
                    if let pendingLoginMessage, conversation?.isReady == true {
                        self.pendingLoginMessage = nil
                        if message == pendingLoginMessage { sendMessage() }
                    }
                    if let conversation, conversation.canSendMessage,
                       let request = appModel.pendingProjectAgentNotification(for: projectRoot) {
                        let sent = conversation.send(request.prompt)
                        appModel.markProjectAgentNotificationSent(request.id, for: projectRoot)
                        if !sent { status = "알림 내용을 Pa에게 전달하지 못했습니다." }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: workers.map(\.name)) { _, names in
            if let selectedWorkerName, !names.contains(selectedWorkerName) {
                self.selectedWorkerName = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).help("Back to projects")
            Text("Pa")
                .font(PassFont.ui(size: 13, weight: .bold))
                .foregroundStyle(.indigo)
                .frame(width: 32, height: 32)
                .background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            Text("\(projectName) · Pa")
                .font(PassFont.ui(size: 14, weight: .semibold))
            Spacer()
            Text("\(workers.count) workers")
                .font(PassFont.ui(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var managerPane: some View {
        VStack(spacing: 0) {
            Group {
                if let conversation {
                    ProjectAgentChatView(conversation: conversation)
                } else if let status {
                    ContentUnavailableView("Pa를 사용할 수 없습니다", systemImage: "exclamationmark.triangle",
                                           description: Text(status))
                } else {
                    ProgressView("Pa를 시작하는 중…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if let status {
                Text(status).font(PassFont.ui(size: 10)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 10) {
                if !attachedFiles.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(attachedFiles, id: \.path) { file in
                                ProjectAgentFileChip(url: file) {
                                    attachedFiles.removeAll { $0 == file }
                                }
                            }
                        }
                    }
                }
                TextField("Pa에게 할 일을 알려주세요…", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($messageFocused)
                    .onKeyPress(.return, phases: [.down]) { press in
                        // Keep the editor's native newline and IME confirmation behavior.
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.command)
                            || press.modifiers.contains(.control) || press.modifiers.contains(.option)
                            || (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true {
                            return .ignored
                        }
                        sendMessage()
                        return .handled
                    }
                    .font(PassFont.ui(size: 13))
                    .lineLimit(4...8)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.12)))
                    .focusEffectDisabled()
                HStack(spacing: 8) {
                    Button(action: chooseFiles) {
                        Image(systemName: "paperclip")
                            .font(PassFont.ui(size: 13))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("파일 첨부")
                    .accessibilityLabel("파일 첨부")
                    Spacer()
                    Text("Enter 보내기 · ⇧Enter 줄바꿈")
                        .font(PassFont.ui(size: 10))
                        .foregroundStyle(.tertiary)
                    Button(action: sendMessage) {
                        Label("Send", systemImage: "arrow.up")
                            .font(PassFont.ui(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(conversation?.canSendMessage != true
                              || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && attachedFiles.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isDropTargeted ? Color.accentColor.opacity(0.12) : .clear)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted,
                    perform: acceptDroppedFiles)
        }
    }

    private var workerPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("워커", systemImage: "person.2")
                    .font(PassFont.ui(size: 11, weight: .semibold))
                Spacer()
                Menu {
                    Button("Pa가 선택") { requestNewWorker(agent: nil) }
                    Divider()
                    ForEach(AgentKind.launchable, id: \.self) { agent in
                        Button(workerLabel(agent)) {
                            requestNewWorker(agent: agent)
                        }
                    }
                } label: {
                    Label("워커 추가", systemImage: "plus")
                        .font(PassFont.ui(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .disabled(conversation?.canSendMessage != true)
                .help("이 프로젝트에 코딩 에이전트 워커 추가")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            if workers.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "person.2")
                        .font(PassFont.ui(size: 18))
                    Text("아직 워커가 없습니다")
                        .font(PassFont.ui(size: 11, weight: .medium))
                    Text("Pa에게 작업을 맡기면 여기에 표시됩니다.")
                        .font(PassFont.ui(size: 10))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(workers) { worker in
                            HStack(spacing: 8) {
                                Text(worker.agent.glyph)
                                    .font(PassFont.ui(size: 13))
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(worker.groupedDisplayName)
                                        .font(PassFont.ui(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Text(workerStatus(worker))
                                        .font(PassFont.ui(size: 10))
                                        .foregroundStyle(worker.needsUser ? Color.orange : Color.secondary)
                                }
                                Spacer()
                                Button(selectedWorkerName == worker.name ? "숨기기" : "보기") {
                                    selectedWorkerName = selectedWorkerName == worker.name ? nil : worker.name
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Menu {
                                    Button("Pa에게 삭제 요청", role: .destructive) {
                                        requestWorkerRemoval(worker)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(PassFont.ui(size: 10, weight: .semibold))
                                }
                                .menuStyle(.borderlessButton)
                                .disabled(conversation?.canSendMessage != true)
                                .help("Pa가 이 워커의 상태를 확인하고 삭제")
                            }
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: selectedWorker == nil ? .infinity : 170)
                if let worker = selectedWorker {
                    Divider()
                    HStack {
                        Text(worker.groupedDisplayName).lineLimit(1)
                        Spacer()
                        Button("Open session") { onOpenWorker(worker.name) }
                            .buttonStyle(.plain).foregroundStyle(.tint)
                        Button("숨기기") { selectedWorkerName = nil }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(PassFont.ui(size: 10))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    LiveProjectTerminal(session: worker)
                        .id(worker.name)
                }
            }
        }
    }

    private func workerStatus(_ worker: Session) -> String {
        if worker.launching { return "Starting" }
        if worker.needsUser { return "Needs your input" }
        if case .working = worker.attention { return "Working" }
        return "Ready"
    }

    private func workerLabel(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "Claude 워커"
        case .codex: return "Codex 워커"
        case .grok: return "Grok 워커"
        case .pi: return "Pi 워커"
        case .shell, .generic: return agent.rawValue
        }
    }

    private func requestNewWorker(agent: AgentKind?) {
        guard let conversation else { return }
        if PiAuthentication.needsLogin() {
            connectAccount()
            return
        }
        let request: String
        if let agent {
            request = "이 프로젝트에 \(agent.rawValue) 코딩 에이전트 워커를 새로 추가해 주세요. 아직 작업은 맡기지 마세요. 지정한 에이전트를 사용할 수 없다면 이유를 알려주세요."
        } else {
            request = "이 프로젝트에 코딩 에이전트 워커를 새로 추가해 주세요. 워커 선택 메모리와 프로젝트 상황을 확인하고 적합한 에이전트를 선택하세요. 아직 작업은 맡기지 마세요."
        }
        if conversation.send(request) { status = nil }
    }

    private func requestWorkerRemoval(_ worker: Session) {
        guard let conversation else { return }
        if PiAuthentication.needsLogin() {
            connectAccount()
            return
        }
        let request = "이 프로젝트의 워커 \(worker.name)을 삭제해 주세요. 먼저 작업 상태와 최근 출력을 확인하세요. 작업 중이거나 입력을 기다리고 있으면 삭제 전에 저에게 알려주세요. 삭제할 수 있으면 passcli session remove 명령을 사용하고 결과를 알려주세요."
        if conversation.send(request) { status = nil }
    }

    private func connectAccount() {
        if appModel.miniTerminals.openPiLogin() {
            status = "작은 터미널에서 Pi 로그인을 완료하세요."
        } else {
            status = "Pi가 설치되어 있지 않습니다. Pi를 설치한 뒤 Pass를 다시 여세요."
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            DispatchQueue.main.async { appendFiles(panel.urls) }
        }
    }

    private func appendFiles(_ urls: [URL]) {
        let candidates = urls.filter { $0.isFileURL && !attachedFiles.contains($0) }
        guard attachedFiles.count + candidates.count <= ProjectAgentAttachments.maximumFiles else {
            status = "파일은 한 번에 8개까지 첨부할 수 있습니다."
            return
        }
        attachedFiles.append(contentsOf: candidates)
        status = nil
    }

    private func acceptDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                else if let value = item as? String { url = URL(string: value) }
                else { url = nil }
                if let url { DispatchQueue.main.async { appendFiles([url]) } }
            }
        }
        return accepted
    }

    private func sendMessage() {
        guard let conversation else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedFiles.isEmpty else { return }
        if PiAuthentication.needsLogin() {
            pendingLoginMessage = text
            status = "Pi 로그인 후 이 요청을 자동으로 보냅니다."
            appModel.miniTerminals.openPiLogin()
            return
        }
        if conversation.send(text, files: attachedFiles) {
            message = ""
            attachedFiles = []
            status = nil
        }
    }
}

private struct ProjectAgentChatView: View {
    let conversation: ProjectAgentConversation
    private let bottomID = "pa-chat-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if conversation.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Pa에게 요청하세요")
                                    .font(PassFont.ui(size: 17, weight: .semibold))
                                Text("이 프로젝트의 작업을 맡기고 진행 상황을 대화로 확인할 수 있습니다.")
                                    .font(PassFont.ui(size: 12)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 30)
                        }
                        ForEach(conversation.messages) { entry in
                            messageView(entry).id(entry.id)
                        }
                        if conversation.isResponding {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(conversation.status)
                            }
                            .font(PassFont.ui(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 700)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .top)
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AgentConversationContentHeightKey.self,
                                           value: geometry.size.height)
                })
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onPreferenceChange(AgentConversationContentHeightKey.self) { _ in
                scrollToBottom(proxy)
            }
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: conversation.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: conversation.messages.last?.text) { _, _ in scrollToBottom(proxy) }
            .onChange(of: conversation.messages.last?.images.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: conversation.isResponding) { _, _ in scrollToBottom(proxy) }
            .onChange(of: conversation.status) { _, _ in scrollToBottom(proxy) }
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Button {
                    conversation.useAutomaticModel()
                } label: {
                    Label("자동 선택", systemImage: conversation.manuallySelectedModel == nil
                          ? "checkmark" : "sparkles")
                }
                Divider()
                ForEach(conversation.selectableModels, id: \.label) { model in
                    Button {
                        conversation.selectModel(model)
                    } label: {
                        if conversation.manuallySelectedModel == model.label {
                            Label(model.label, systemImage: "checkmark")
                        } else {
                            Text(model.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(conversation.manuallySelectedModel == nil ? "자동 선택" : "직접 선택") · \(conversation.modelLabel)")
                    Image(systemName: "chevron.down")
                }
                .font(PassFont.ui(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .disabled(!conversation.canChangeModel)
            .help("Pa 모델 선택")
            .padding(7)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo(bottomID, anchor: .bottom) }
    }

    @ViewBuilder
    private func messageView(_ entry: ProjectAgentMessage) -> some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 7) {
                    AgentMarkdownView(source: entry.text, projectRoot: conversation.projectRoot)
                    if !entry.attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(entry.attachments, id: \.path) { file in
                                ProjectAgentFileChip(url: file, onRemove: nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            if !entry.text.isEmpty || !entry.images.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if !entry.text.isEmpty {
                        AgentMarkdownView(source: entry.text, projectRoot: conversation.projectRoot)
                    }
                    ForEach(Array(entry.images.enumerated()), id: \.offset) { _, data in
                        AgentImageDataView(data: data)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        case .activity:
            ProjectAgentActivityRow(entry: entry)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.circle")
                .font(PassFont.ui(size: 11))
                .textSelection(.enabled)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProjectAgentActivityRow: View {
    let entry: ProjectAgentMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: entry.toolIsError ? "exclamationmark.circle" : "wrench.and.screwdriver")
                        .frame(width: 14)
                    Text(entry.toolName ?? "도구")
                        .fontWeight(.medium)
                    if let summary = entry.toolSummary {
                        Text(summary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if entry.toolIsRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(entry.toolIsError ? "실패" : "완료")
                            .foregroundStyle(entry.toolIsError ? Color.orange : Color.secondary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(PassFont.ui(size: 9, weight: .semibold))
                }
                .font(PassFont.ui(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.toolName ?? "도구") \(entry.toolIsRunning ? "실행 중" : entry.toolIsError ? "실패" : "완료")")
            .accessibilityHint(expanded ? "도구 실행 세부사항 접기" : "도구 실행 세부사항 펼치기")

            if expanded {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let input = entry.toolInput {
                            detail("입력", text: input)
                        }
                        detail("결과", text: entry.text.isEmpty
                               ? (entry.toolIsRunning ? "실행 중…" : "표시할 텍스트 결과가 없습니다.")
                               : entry.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(maxHeight: 300)
                .background(Color.primary.opacity(0.03))
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(PassFont.ui(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.custom("SF Mono", size: 10))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProjectAgentFileChip: View {
    let url: URL
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if ProjectAgentAttachments.isImage(url), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "doc")
                    .font(PassFont.ui(size: 17))
                    .frame(width: 34, height: 34)
            }
            Text(ProjectAgentAttachments.displayName(for: url))
                .font(PassFont.ui(size: 10))
                .lineLimit(1)
                .frame(maxWidth: 130, alignment: .leading)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(ProjectAgentAttachments.displayName(for: url)) 첨부 제거")
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct LiveProjectTerminal: View {
    let session: Session
    @Environment(AppModel.self) private var appModel
    @State private var terminal: TerminalController?

    var body: some View {
        Group {
            if let terminal {
                TerminalPaneView(controller: terminal) { command in
                    appModel.miniTerminals.run(command, for: session)
                }
            } else {
                ProgressView("Connecting terminal…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: session.name) {
            let controller = TerminalController(session: session.name)
            terminal = controller
            await controller.start()
            defer { controller.detach(); terminal = nil }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
        }
    }
}
