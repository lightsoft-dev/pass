import SwiftUI

/// The spec documents screen: pick a project → see its ONE document (`.pass/specs.json`) —
/// the dev-server row on top, then the numbered specs, each with an editable title/detail,
/// a status badge, and agent actions (implement / verify / rework).
struct SpecsView: View {
    var onBack: () -> Void
    var onOpenSession: (String) -> Void

    @Environment(AppModel.self) private var appModel
    @State private var selectedRoot: String = ""
    @State private var expanded: Int?        // spec number with the detail editor open
    @State private var newSpecTitle = ""
    @State private var status: String?       // transient action feedback

    private var projects: [Project] { appModel.projects?.projects ?? [] }
    private var document: SpecDocument? { appModel.specs?.document(for: selectedRoot) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if selectedRoot.isEmpty {
                emptyState("folder.badge.plus", "Pick a project",
                           "Each project keeps ONE spec document at .pass/specs.json.")
            } else if document == nil {
                // No document yet — creating it is an explicit act (nothing is written into
                // the repository until the user asks for it).
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "doc.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("No spec document yet").font(.system(size: 15, weight: .medium))
                    Text(".pass/specs.json will be created inside this project —\ncommit it to share the specs.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Create spec document") {
                        do { try appModel.specs?.ensureDocument(projectRoot: selectedRoot) }
                        catch { status = "⚠ \(error.localizedDescription)" }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                content
            }
        }
        .onAppear { selectInitialProject() }
        // Poll the file so agent edits (status flips) show up while you watch.
        .task(id: selectedRoot) {
            guard !selectedRoot.isEmpty else { return }
            while !Task.isCancelled {
                appModel.specs?.reload(projectRoot: selectedRoot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Back to sessions (⌘[)")
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text("Specs").font(.system(size: 14, weight: .semibold))
            Picker("", selection: $selectedRoot) {
                ForEach(projects) { p in
                    Text(p.name).tag(p.rootPath)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 260)
            Spacer()
            if let status {
                Text(status).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([SpecStore.fileURL(projectRoot: selectedRoot)])
            } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(selectedRoot.isEmpty || document == nil)
                .help("Reveal specs.json in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                developmentSection
                Divider()
                specsSection
                if let err = appModel.specs?.errorByProject[selectedRoot] {
                    Text("⚠ \(err)").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .padding(14)
        }
    }

    // MARK: development server row

    @ViewBuilder
    private var developmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Development").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("run command — e.g. pnpm dev", text: devBinding(\.command))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                TextField("subdir", text: devBinding(\.workingDirectory))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .frame(width: 110)
            }
            HStack(spacing: 8) {
                TextField("URL — e.g. http://localhost:3000", text: devBinding(\.url))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                if let live = appModel.specPreviewSession(projectRoot: selectedRoot) {
                    Button("Open session") { onOpenSession(live.name) }.controlSize(.small)
                    Button("Stop", role: .destructive) {
                        appModel.stopSpecPreview(projectRoot: selectedRoot)
                    }.controlSize(.small)
                } else {
                    Button("Run") {
                        let root = selectedRoot
                        Task {
                            if case .failure(let msg) = await appModel.startSpecPreview(projectRoot: root) {
                                status = "⚠ \(msg)"
                            } else { status = nil }
                        }
                    }.controlSize(.small)
                }
                if let url = document?.development.url, !url.isEmpty {
                    Button("Open URL") {
                        if let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
                            NSWorkspace.shared.open(u)
                        }
                    }.controlSize(.small)
                }
            }
        }
    }

    // MARK: specs list

    @ViewBuilder
    private var specsSection: some View {
        Text("Specs").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        if let doc = document, !doc.specs.isEmpty {
            ForEach(doc.specs) { spec in
                SpecRow(
                    projectRoot: selectedRoot,
                    spec: spec,
                    expanded: expanded == spec.number,
                    onToggle: { expanded = (expanded == spec.number) ? nil : spec.number },
                    onOpenSession: onOpenSession,
                    onStatus: { status = $0 }
                )
            }
        } else {
            Text("No specs yet — name the first one below.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        HStack(spacing: 8) {
            Image(systemName: "plus.circle").foregroundStyle(.secondary)
            TextField("new spec title · ⏎ to add", text: $newSpecTitle)
                .textFieldStyle(.plain).font(.system(size: 12))
                .onSubmit {
                    let title = newSpecTitle.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return }
                    do {
                        let spec = try appModel.specs?.addSpec(projectRoot: selectedRoot, title: title)
                        newSpecTitle = ""
                        expanded = spec?.number
                    } catch { status = "⚠ \(error.localizedDescription)" }
                }
        }
        .padding(.top, 4)
    }

    // MARK: helpers

    private func selectInitialProject() {
        guard selectedRoot.isEmpty else { return }
        // Debug hook (PASS_DEBUG_SPECS=<root>) pins the initial project for headless checks.
        if let dbg = ProcessInfo.processInfo.environment["PASS_DEBUG_SPECS"], dbg.hasPrefix("/") {
            selectedRoot = dbg
        } else if let root = appModel.sessions?.sessions.first?.projectRoot,
                  projects.contains(where: { $0.rootPath == root }) {
            // Prefer the project of the most recent session, else the first registered one.
            selectedRoot = root
        } else if let first = projects.first {
            selectedRoot = first.rootPath
        }
        if !selectedRoot.isEmpty { appModel.specs?.reload(projectRoot: selectedRoot) }
    }

    /// Live-editing binding into the document's development block (writes through the store).
    private func devBinding(_ keyPath: WritableKeyPath<SpecDevelopment, String>) -> Binding<String> {
        Binding(
            get: { document?.development[keyPath: keyPath] ?? "" },
            set: { new in
                try? appModel.specs?.updateDevelopment(projectRoot: selectedRoot) { $0[keyPath: keyPath] = new }
            }
        )
    }

    private func emptyState(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

/// One numbered spec: "#N [status] title" — expands to the detail editor + agent actions.
private struct SpecRow: View {
    let projectRoot: String
    let spec: Spec
    let expanded: Bool
    let onToggle: () -> Void
    let onOpenSession: (String) -> Void
    let onStatus: (String?) -> Void

    @Environment(AppModel.self) private var appModel
    @State private var reworkText = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(spec.number)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                statusBadge
                TextField("title", text: specBinding(\.title))
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                Spacer()
                if let session = liveAgentSession {
                    Button { onOpenSession(session.name) } label: {
                        Image(systemName: "terminal")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Open the session working on this spec")
                }
                Button { onToggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())

            if expanded {
                TextEditor(text: specBinding(\.detail))
                    .font(.system(size: 12))
                    .frame(minHeight: 70, maxHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if let last = spec.feedback.last {
                    Text("↩ \(last.text)").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                }

                HStack(spacing: 8) {
                    Button("Implement") { run(.implement) }
                        .controlSize(.small).disabled(running)
                    Button("Verify") { run(.verify) }
                        .controlSize(.small).disabled(running)
                    TextField("rework feedback…", text: $reworkText)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        .onSubmit { submitRework() }
                    Button("Rework") { submitRework() }
                        .controlSize(.small).disabled(running || reworkText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(role: .destructive) {
                        try? appModel.specs?.removeSpec(projectRoot: projectRoot, number: spec.number)
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Delete this spec (its number is never reused)")
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(expanded ? 0.05 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var liveAgentSession: Session? {
        guard let name = spec.agentSession else { return nil }
        return appModel.sessions?.session(named: name)
    }

    private var statusBadge: some View {
        Menu {
            ForEach(SpecStatus.allCases, id: \.self) { s in
                Button(s.label) {
                    try? appModel.specs?.updateSpec(projectRoot: projectRoot, number: spec.number) { $0.status = s }
                }
            }
        } label: {
            Text(spec.status.label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(statusTint.opacity(0.18))
                .foregroundStyle(statusTint)
                .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Work status — agents update this in specs.json too")
    }

    private var statusTint: Color {
        switch spec.status {
        case .draft:        return .secondary
        case .ready:        return .blue
        case .implementing: return .purple
        case .verifying:    return .teal
        case .needsReview:  return .orange
        case .verified:     return .green
        case .blocked:      return .red
        }
    }

    private func run(_ action: AppModel.SpecAgentAction) {
        running = true
        onStatus(nil)
        let root = projectRoot, number = spec.number
        Task {
            let result = await appModel.runSpecAgent(projectRoot: root, number: number, action: action)
            running = false
            switch result {
            case .success(let session): onOpenSession(session)
            case .failure(let message): onStatus("⚠ \(message)")
            }
        }
    }

    private func submitRework() {
        let text = reworkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reworkText = ""
        run(.rework(feedback: text))
    }

    private func specBinding(_ keyPath: WritableKeyPath<Spec, String>) -> Binding<String> {
        Binding(
            get: { currentSpec()?[keyPath: keyPath] ?? "" },
            set: { new in
                try? appModel.specs?.updateSpec(projectRoot: projectRoot, number: spec.number) {
                    $0[keyPath: keyPath] = new
                }
            }
        )
    }

    private func currentSpec() -> Spec? {
        appModel.specs?.document(for: projectRoot)?.specs.first { $0.number == spec.number }
    }
}
