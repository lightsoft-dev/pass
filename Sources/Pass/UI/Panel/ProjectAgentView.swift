import SwiftUI

/// A project's Pi coordinator with worker terminals revealed only on request.
struct ProjectAgentView: View {
    let projectRoot: String
    let sessions: [Session]
    let initialDraft: String
    let onBack: () -> Void
    let onOpenWorker: (String) -> Void

    @Environment(AppModel.self) private var appModel
    @State private var selectedWorkerName: String?
    @State private var message = ""
    @State private var status: String?
    @State private var pendingLoginMessage: String?
    @State private var conversation: ProjectAgentConversation?

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
            appModel.piUpdater.refreshVersion()
            conversation = nil
            message = initialDraft
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
        .task(id: projectRoot) {
            while !Task.isCancelled {
                if !PiAuthentication.needsLogin() {
                    if status?.contains("로그인") == true { status = nil }
                    if let pendingLoginMessage, conversation?.isReady == true {
                        self.pendingLoginMessage = nil
                        if message == pendingLoginMessage { sendMessage() }
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
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.indigo)
                .frame(width: 32, height: 32)
                .background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(projectName) · Pa")
                    .font(.system(size: 14, weight: .semibold))
                Text("Project agent · Coordinates this project's work")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(workers.count) workers")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var managerPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Pa · Project agent", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let version = appModel.piUpdater.version {
                    Text("Pi v\(version)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button {
                    appModel.piUpdater.update {
                        appModel.restartProjectAgentsAfterPiUpdate()
                    }
                } label: {
                    if appModel.piUpdater.isUpdating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Pi 업데이트")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tint)
                .disabled(appModel.piUpdater.isUpdating || conversation?.isResponding == true)
                .help("설치된 Pi를 최신 버전으로 업데이트")
                Button("Pi 계정 연결", action: connectAccount)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tint)
                    .help("Choose a model provider and sign in through Pi")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
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
                Text(status).font(.system(size: 10)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 6)
            }
            if let updateStatus = appModel.piUpdater.status {
                Text(updateStatus).font(.system(size: 10))
                    .foregroundStyle(appModel.piUpdater.isUpdating ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 6)
            }
            HStack(spacing: 8) {
                TextField("Pa에게 할 일을 알려주세요…", text: $message)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendMessage)
                Button("Send", action: sendMessage)
                    .disabled(conversation?.canSendMessage != true
                              || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
    }

    private var workerPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Worker sessions", systemImage: "person.2")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("Terminal details hidden")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            if workers.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "person.2")
                        .font(.system(size: 18))
                    Text("No worker yet")
                        .font(.system(size: 11, weight: .medium))
                    Text("Pa에게 작업을 맡기면 여기에 표시됩니다.")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(workers) { worker in
                            HStack(spacing: 8) {
                                Text(worker.agent.glyph)
                                    .font(.system(size: 13))
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(worker.displayName)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Text(workerStatus(worker))
                                        .font(.system(size: 10))
                                        .foregroundStyle(worker.needsUser ? Color.orange : Color.secondary)
                                }
                                Spacer()
                                Button(selectedWorkerName == worker.name ? "숨기기" : "보기") {
                                    selectedWorkerName = selectedWorkerName == worker.name ? nil : worker.name
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
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
                        Text(worker.displayName).lineLimit(1)
                        Spacer()
                        Button("Open session") { onOpenWorker(worker.name) }
                            .buttonStyle(.plain).foregroundStyle(.tint)
                        Button("숨기기") { selectedWorkerName = nil }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10))
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

    private func connectAccount() {
        if appModel.miniTerminals.openPiLogin() {
            status = "작은 터미널에서 Pi 로그인을 완료하세요."
        } else {
            status = "Pi가 설치되어 있지 않습니다. Pi를 설치한 뒤 Pass를 다시 여세요."
        }
    }

    private func sendMessage() {
        guard let conversation else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if PiAuthentication.needsLogin() {
            pendingLoginMessage = text
            status = "Pi 로그인 후 이 요청을 자동으로 보냅니다."
            appModel.miniTerminals.openPiLogin()
            return
        }
        if conversation.send(text) {
            message = ""
            status = nil
        }
    }
}

private struct ProjectAgentChatView: View {
    let conversation: ProjectAgentConversation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pa에게 요청하세요")
                                .font(.system(size: 17, weight: .semibold))
                            Text("이 프로젝트의 작업을 맡기고 진행 상황을 대화로 확인할 수 있습니다.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
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
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 700)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: conversation.messages.count) { _, _ in
                if let id = conversation.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
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
                .font(.system(size: 10))
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

    @ViewBuilder
    private func messageView(_ entry: ProjectAgentMessage) -> some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            if !entry.text.isEmpty {
                Text(entry.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        case .activity:
            Text(entry.text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.circle")
                .font(.system(size: 11))
                .textSelection(.enabled)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
