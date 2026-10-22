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
    @State private var readableManager = true

    private var projectName: String { URL(fileURLWithPath: projectRoot).lastPathComponent }
    private var manager: Session? {
        sessions.first { $0.projectRoot == projectRoot && $0.isProjectAgent }
    }
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
            if message.isEmpty { message = initialDraft }
            guard let store = appModel.sessions else { return }
            switch await store.ensureProjectAgent(projectRoot: projectRoot) {
            case .success: status = nil
            case .failure(let error): status = error.localizedDescription
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
            Text("π")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 32, height: 32)
                .background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(projectName) · Project agent")
                    .font(.system(size: 14, weight: .semibold))
                Text("Coordinates work across this project's agents")
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
                Label("Project agent", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Pi 계정 연결", action: connectAccount)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tint)
                    .disabled(manager == nil)
                    .help("Choose a model provider and sign in through Pi")
                SessionPresentationPicker(readableMode: $readableManager)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            Group {
                if let manager {
                    if readableManager {
                        ConversationPaneView(session: manager)
                    } else {
                        LiveProjectTerminal(session: manager)
                    }
                } else if let status {
                    ContentUnavailableView("Project agent unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(status))
                } else {
                    ProgressView("Starting project agent…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if let status, manager != nil {
                Text(status).font(.system(size: 10)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 6)
            }
            HStack(spacing: 8) {
                TextField("Tell the project agent what to do…", text: $message)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendMessage)
                Button("Send", action: sendMessage)
                    .disabled(manager == nil || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    Text("Ask the project agent to start one.")
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
        guard let manager else { return }
        readableManager = false
        status = nil
        Task {
            switch await appModel.reply(to: manager.name, text: "/login") {
            case .delivered: break
            case .refusedShell:
                status = "Pi is not running. Check its terminal before connecting an account."
            case .error(let error):
                status = error
            }
        }
    }

    private func sendMessage() {
        guard let manager else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        status = nil
        Task {
            switch await appModel.reply(to: manager.name, text: text) {
            case .delivered: break
            case .refusedShell:
                status = "Pi is not ready yet. Switch to Terminal to inspect its startup."
                message = text
            case .error(let error):
                status = error
                message = text
            }
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
