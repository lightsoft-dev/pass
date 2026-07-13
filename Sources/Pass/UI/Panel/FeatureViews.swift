import SwiftUI

/// Project-scoped library of executable feature documents.
struct FeatureLibraryView: View {
    @Environment(AppModel.self) private var appModel
    let onBack: () -> Void
    let onOpen: (String, String) -> Void

    @State private var selectedProjectRoot: String = ""
    @State private var message: String?

    private var projects: [Project] { appModel.projects?.projects ?? [] }
    private var documents: [FeatureDocument] {
        guard !selectedProjectRoot.isEmpty else { return [] }
        return appModel.features?.documents(for: selectedProjectRoot) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if projects.isEmpty {
                emptyState(
                    icon: "folder.badge.plus",
                    title: "Add a project first",
                    subtitle: "Feature documents live inside a project's .pass/features folder."
                )
            } else if documents.isEmpty {
                emptyState(
                    icon: "doc.badge.plus",
                    title: "No feature documents",
                    subtitle: "Create an executable specification for this project."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(documents) { document in
                            FeatureDocumentRow(document: document)
                                .contentShape(Rectangle())
                                .onTapGesture { onOpen(selectedProjectRoot, document.id) }
                        }
                    }
                    .padding(10)
                }
            }
            if let error = appModel.features?.loadErrorByProject[selectedProjectRoot] {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(10)
            } else if let message {
                Divider()
                Text(message).font(.system(size: 10)).foregroundStyle(.orange).padding(10)
            }
        }
        .onAppear { selectInitialProject() }
        .onChange(of: projects.map(\.rootPath)) { _, _ in selectInitialProject() }
        .task(id: selectedProjectRoot) {
            guard !selectedProjectRoot.isEmpty else { return }
            while !Task.isCancelled {
                appModel.features?.reload(projectRoot: selectedProjectRoot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .help("Back to sessions (⌘[ or ⌘W)")
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
            Text("Features").font(.system(size: 15, weight: .semibold))
            if !projects.isEmpty {
                Picker("Project", selection: $selectedProjectRoot) {
                    ForEach(projects) { project in
                        Text(project.name).tag(project.rootPath)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .onChange(of: selectedProjectRoot) { _, root in
                    message = nil
                    appModel.features?.reload(projectRoot: root)
                }
            }
            Spacer()
            Button {
                appModel.features?.reload(projectRoot: selectedProjectRoot)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(selectedProjectRoot.isEmpty)
            .help("Reload JSON from disk")
            Button(action: createFeature) {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedProjectRoot.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func selectInitialProject() {
        if !projects.contains(where: { $0.rootPath == selectedProjectRoot }) {
            selectedProjectRoot = projects.first?.rootPath ?? ""
        }
        if !selectedProjectRoot.isEmpty {
            appModel.features?.reload(projectRoot: selectedProjectRoot)
        }
    }

    private func createFeature() {
        do {
            guard let document = try appModel.features?.create(projectRoot: selectedProjectRoot) else { return }
            onOpen(selectedProjectRoot, document.id)
        } catch {
            message = error.localizedDescription
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !selectedProjectRoot.isEmpty {
                Button("Create feature") { createFeature() }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct FeatureDocumentRow: View {
    let document: FeatureDocument

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: document.status.symbol)
                .foregroundStyle(document.status.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(document.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(document.status.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(document.status.color)
                }
                Text(document.summary.isEmpty ? "No summary yet" : document.summary)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Text("\(document.acceptanceCriteria.count) acceptance criteria · \(document.implementation.checks.filter { $0.status == .passed }.count) checks passed")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(11)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Read/edit/run/review surface for one feature contract.
struct FeatureDetailView: View {
    @Environment(AppModel.self) private var appModel
    let projectRoot: String
    let document: FeatureDocument
    let onBack: () -> Void
    let onOpenSession: (String) -> Void

    @State private var editing = false
    @State private var busy = false
    @State private var actionMessage: String?
    @State private var feedback = ""

    @State private var title: String
    @State private var summary: String
    @State private var status: FeatureStatus
    @State private var requirementsText: String
    @State private var criteriaText: String
    @State private var devCommand: String
    @State private var workingDirectory: String
    @State private var localURL: String
    @State private var testCommand: String
    @State private var guideText: String
    @State private var preferredAgent: AgentKind

    init(projectRoot: String, document: FeatureDocument, onBack: @escaping () -> Void,
         onOpenSession: @escaping (String) -> Void) {
        self.projectRoot = projectRoot
        self.document = document
        self.onBack = onBack
        self.onOpenSession = onOpenSession
        _title = State(initialValue: document.title)
        _summary = State(initialValue: document.summary)
        _status = State(initialValue: document.status)
        _requirementsText = State(initialValue: document.requirements.joined(separator: "\n"))
        _criteriaText = State(initialValue: document.acceptanceCriteria.joined(separator: "\n"))
        _devCommand = State(initialValue: document.development.command)
        _workingDirectory = State(initialValue: document.development.workingDirectory)
        _localURL = State(initialValue: document.development.url)
        _testCommand = State(initialValue: document.development.testCommand)
        _guideText = State(initialValue: document.development.guide.joined(separator: "\n"))
        _preferredAgent = State(initialValue: document.implementation.preferredAgent)
    }

    private var preview: Session? {
        appModel.previewSession(projectRoot: projectRoot, featureID: document.id)
    }

    private var missingFiles: [String] {
        appModel.features?.missingImplementationFiles(for: document, projectRoot: projectRoot) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editing { editor } else { detail }
            if let actionMessage {
                Divider()
                Text(actionMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(actionMessage.hasPrefix("Error") ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
        .onChange(of: document.updatedAt) { _, _ in
            if !editing { resetDraft() }
        }
        .task(id: document.id) {
            while !Task.isCancelled {
                appModel.features?.reload(projectRoot: projectRoot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).help("Back to features")
            Image(systemName: document.status.symbol).foregroundStyle(document.status.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(document.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(document.status.label)
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(document.status.color)
            Button {
                appModel.revealFeatureFile(projectRoot: projectRoot, featureID: document.id)
            } label: { Image(systemName: "doc.text") }
                .buttonStyle(.plain).help("Reveal JSON file")
            Button(editing ? "Cancel" : "Edit") {
                if editing { resetDraft() }
                editing.toggle()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !document.summary.isEmpty {
                    Text(document.summary).font(.system(size: 13)).textSelection(.enabled)
                }

                FeatureSection(title: "Requirements", icon: "list.bullet.rectangle") {
                    BulletList(items: document.requirements, empty: "No requirements yet")
                }
                FeatureSection(title: "Acceptance", icon: "checklist") {
                    BulletList(items: document.acceptanceCriteria, numbered: true,
                               empty: "No acceptance criteria yet")
                }
                developmentSection
                implementationSection
                agentSection
                reviewSection
            }
            .padding(12)
        }
    }

    private var developmentSection: some View {
        FeatureSection(title: "Try it locally", icon: "play.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                if document.development.command.isEmpty {
                    Text("Add a development command to make this feature runnable.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(document.development.command)
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        if let preview {
                            Label("Running", systemImage: "circle.fill")
                                .font(.system(size: 9)).foregroundStyle(.green)
                            Button("Terminal") { onOpenSession(preview.name) }.controlSize(.small)
                            Button("Stop") {
                                appModel.stopFeaturePreview(projectRoot: projectRoot, featureID: document.id)
                            }.controlSize(.small)
                        } else {
                            Button("Start server") { runPreview() }
                                .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy)
                        }
                    }
                }
                if !document.development.url.isEmpty {
                    Button {
                        if !appModel.openFeatureURL(document.development.url) {
                            actionMessage = "Error: use an http:// or https:// URL."
                        }
                    } label: {
                        Label("Open \(document.development.url)", systemImage: "safari")
                    }
                    .buttonStyle(.link)
                }
                BulletList(items: document.development.guide, numbered: true,
                           empty: "Add a short human test guide.")
            }
        }
    }

    private var implementationSection: some View {
        FeatureSection(title: "Implementation status", icon: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: 7) {
                if !document.implementation.summary.isEmpty {
                    Text(document.implementation.summary).font(.system(size: 11))
                }
                if !document.implementation.files.isEmpty {
                    Text(document.implementation.files.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !missingFiles.isEmpty {
                    Label("Missing claimed files: \(missingFiles.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                if document.implementation.checks.isEmpty {
                    Text("No checks recorded yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(document.implementation.checks) { check in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: check.status.symbol).foregroundStyle(check.status.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.name).font(.system(size: 11, weight: .medium))
                                if !check.details.isEmpty {
                                    Text(check.details).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var agentSection: some View {
        FeatureSection(title: "Local agent", icon: "cpu") {
            HStack(spacing: 7) {
                Button("Implement") { runAgent(.implement) }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy)
                Button("Verify") { runAgent(.verify) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                if let name = document.implementation.agentSession,
                   appModel.sessions?.session(named: name) != nil {
                    Button("Open session") { onOpenSession(name) }.buttonStyle(.link)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Text(document.implementation.preferredAgent.glyph + " " + document.implementation.preferredAgent.rawValue)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private var reviewSection: some View {
        FeatureSection(title: "Human review", icon: "person.crop.circle.badge.checkmark") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(document.reviews.suffix(3)) { review in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(review.feedback).font(.system(size: 11))
                        Text(review.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    TextField("What behaved incorrectly?", text: $feedback).textFieldStyle(.roundedBorder)
                    Button("Request changes") { runAgent(.rework(feedback: feedback)) }
                        .controlSize(.small).disabled(busy || feedback.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Mark verified") { markVerified() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(document.status == .verified || busy)
            }
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EditField("Title", text: $title)
                EditArea("Summary", text: $summary, height: 58)
                HStack {
                    Text("Status").font(.system(size: 11, weight: .semibold)).frame(width: 110, alignment: .leading)
                    Picker("Status", selection: $status) {
                        ForEach(FeatureStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden()
                    Spacer()
                    Text("ID is stable: \(document.id)")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                EditArea("Requirements", text: $requirementsText, height: 82, hint: "One per line")
                EditArea("Acceptance", text: $criteriaText, height: 82, hint: "One observable result per line")
                Divider()
                Text("Local development").font(.system(size: 12, weight: .semibold))
                EditField("Run command", text: $devCommand, placeholder: "npm run dev")
                EditField("Working directory", text: $workingDirectory, placeholder: ".")
                EditField("Local URL", text: $localURL, placeholder: "http://localhost:3000/login")
                EditField("Test command", text: $testCommand, placeholder: "npm test -- login")
                EditArea("Test guide", text: $guideText, height: 82, hint: "One human step per line")
                HStack {
                    Text("Agent").font(.system(size: 11, weight: .semibold)).frame(width: 110, alignment: .leading)
                    Picker("Agent", selection: $preferredAgent) {
                        ForEach(AgentKind.launchable, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                }
                HStack {
                    Spacer()
                    Button("Cancel") { resetDraft(); editing = false }
                    Button("Save JSON") { saveDraft() }
                        .buttonStyle(.borderedProminent)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func runPreview() {
        busy = true; actionMessage = "Starting development server…"
        Task {
            let result = await appModel.startFeaturePreview(projectRoot: projectRoot, featureID: document.id)
            busy = false
            switch result {
            case .success: actionMessage = "Development server is running in tmux. Follow the guide above."
            case .failure(let error): actionMessage = "Error: \(error)"
            }
        }
    }

    private func runAgent(_ action: AppModel.FeatureAgentAction) {
        busy = true; actionMessage = "Preparing agent contract…"
        Task {
            let result = await appModel.runFeatureAgent(projectRoot: projectRoot, featureID: document.id, action: action)
            busy = false
            switch result {
            case .success(let session):
                actionMessage = "Sent to \(session). Status will refresh from JSON."
                if case .rework = action { feedback = "" }
            case .failure(let error): actionMessage = "Error: \(error)"
            }
        }
    }

    private func markVerified() {
        do {
            try appModel.features?.markVerified(projectRoot: projectRoot, id: document.id)
            actionMessage = "Marked verified by human review."
        } catch {
            actionMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func saveDraft() {
        var copy = document
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.status = status
        copy.requirements = lines(requirementsText)
        copy.acceptanceCriteria = lines(criteriaText)
        copy.development.command = devCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.development.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.development.workingDirectory.isEmpty { copy.development.workingDirectory = "." }
        copy.development.url = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.development.testCommand = testCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.development.guide = lines(guideText)
        copy.implementation.preferredAgent = preferredAgent
        do {
            try appModel.features?.save(copy, projectRoot: projectRoot)
            editing = false
            actionMessage = "Saved to .pass/features/\(document.id).json"
        } catch {
            actionMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func resetDraft() {
        title = document.title
        summary = document.summary
        status = document.status
        requirementsText = document.requirements.joined(separator: "\n")
        criteriaText = document.acceptanceCriteria.joined(separator: "\n")
        devCommand = document.development.command
        workingDirectory = document.development.workingDirectory
        localURL = document.development.url
        testCommand = document.development.testCommand
        guideText = document.development.guide.joined(separator: "\n")
        preferredAgent = document.implementation.preferredAgent
    }

    private func lines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

private struct FeatureSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        GroupBox {
            content.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
        } label: {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .semibold))
        }
    }
}

private struct BulletList: View {
    let items: [String]
    var numbered = false
    let empty: String

    var body: some View {
        if items.isEmpty {
            Text(empty).font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text(numbered ? "\(index + 1)." : "•")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Text(item).font(.system(size: 11)).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct EditField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""

    init(_ label: String, text: Binding<String>, placeholder: String = "") {
        self.label = label; _text = text; self.placeholder = placeholder
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 11, weight: .semibold)).frame(width: 110, alignment: .leading)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

private struct EditArea: View {
    let label: String
    @Binding var text: String
    let height: CGFloat
    var hint = ""

    init(_ label: String, text: Binding<String>, height: CGFloat, hint: String = "") {
        self.label = label; _text = text; self.height = height; self.hint = hint
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11, weight: .semibold))
                if !hint.isEmpty { Text(hint).font(.system(size: 8)).foregroundStyle(.tertiary) }
            }.frame(width: 110, alignment: .leading)
            TextEditor(text: $text)
                .font(.system(size: 11))
                .frame(height: height)
                .padding(4)
                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator.opacity(0.4)))
        }
    }
}

private extension FeatureStatus {
    var color: Color {
        switch self {
        case .draft: return .secondary
        case .ready: return .blue
        case .implementing, .verifying: return .indigo
        case .needsReview: return .orange
        case .verified: return .green
        case .blocked: return .red
        }
    }
}

private extension FeatureCheckStatus {
    var symbol: String {
        switch self {
        case .pending: return "circle"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .passed: return .green
        case .failed: return .red
        }
    }
}
