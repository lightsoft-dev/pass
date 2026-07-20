import AppKit
import SwiftUI

/// Human-in-the-loop AI extension authoring. The agent gets a normal pass session, but this
/// sheet owns the lifecycle: describe → generate → inspect code/permissions → rework/enable.
struct ExtensionBuilderView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var showingCreate = true
    @State private var extensionId = ""
    @State private var goal = ""
    @State private var feedback = ""
    @State private var working = false
    @State private var message: String?

    private var builder: ExtensionBuilder { appModel.extensionBuilder }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 210)
                    .frame(maxHeight: .infinity)
                Divider()
                Group {
                    if showingCreate {
                        createView
                    } else if let build = selectedBuild {
                        reviewView(build)
                    } else {
                        emptyView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 820, height: 680)
        .onAppear {
            if let first = builder.builds.first {
                selection = first.extensionId
                showingCreate = false
                loadReviewIfNeeded(first)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Extension Builder").font(.system(size: 16, weight: .semibold))
                Text("An agent writes the files; you review and enable them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingCreate = true
                selection = nil
                message = nil
            } label: {
                Label("New extension", systemImage: "plus")
            }
            Button("Done") { dismiss() }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BUILDS")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.top, 12)
            ScrollView {
                LazyVStack(spacing: 4) {
                    if builder.builds.isEmpty {
                        Text("No builds yet")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    ForEach(builder.builds) { build in
                        Button {
                            selection = build.extensionId
                            showingCreate = false
                            message = nil
                            loadReviewIfNeeded(build)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: statusIcon(build.status))
                                    .foregroundStyle(statusColor(build.status)).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(build.extensionId)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                    Text(build.status.label)
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(selection == build.extensionId && !showingCreate
                                        ? Color.accentColor.opacity(0.14) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    private var createView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Describe the extension")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Claude receives the extension API, works in a disabled folder, and returns the result for review.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Extension ID").font(.system(size: 12, weight: .medium))
                    TextField("optional — generated automatically", text: $extensionId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("Lowercase letters, digits, and hyphens. This becomes ~/.pass/extensions/<id>.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("What should it do?").font(.system(size: 12, weight: .medium))
                    TextEditor(text: $goal)
                        .font(.system(size: 13))
                        .frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Include desired commands, events, and UI behavior. For custom UI, ask for an HTML/CSS/JS window.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let message { statusMessage(message) }

                HStack {
                    Spacer()
                    Button {
                        startBuild()
                    } label: {
                        if working { ProgressView().controlSize(.small) }
                        else { Label("Build with Claude", systemImage: "wand.and.stars") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(26)
        }
    }

    private func reviewView(_ build: ExtensionBuild) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(build.extensionId)
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        Label(build.status.label, systemImage: statusIcon(build.status))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(statusColor(build.status))
                    }
                    Spacer()
                    Button("Reveal folder") { reveal(build.extensionId) }
                    Button("Check files") {
                        builder.refreshReview(extensionId: build.extensionId)
                        message = nil
                    }
                }

                Text(build.goal).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let session = build.sessionName {
                    LabeledContent("Agent session") {
                        Text(session).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.system(size: 11))
                }

                if build.status == .generating || build.status == .reworking {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(build.status == .generating
                             ? "The agent is creating and validating the extension."
                             : "The agent is applying your feedback.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let summary = build.summary, !summary.isEmpty {
                    reviewSection("Agent summary") {
                        Text(summary).font(.system(size: 12)).textSelection(.enabled)
                    }
                }

                if let review = builder.review(for: build.extensionId) {
                    permissionsSection(review)
                    contributionsSection(review)
                    problemsSection(review)
                    filesSection(review)
                } else if build.status == .needsReview || build.status == .approved {
                    ProgressView().controlSize(.small)
                        .onAppear { builder.refreshReview(extensionId: build.extensionId) }
                }

                if build.status == .needsReview {
                    reworkSection(build)
                    approvalSection(build)
                } else if build.status == .approved {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Enabled with the reviewed content fingerprint. Any later file change disables it on Reload.")
                            .font(.system(size: 12))
                        Spacer()
                        Button("Remove from builder") {
                            builder.forget(extensionId: build.extensionId)
                            selection = nil
                            showingCreate = true
                        }
                    }
                    .padding(12).background(Color.green.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let message { statusMessage(message) }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func contributionsSection(_ review: ExtensionBuildReview) -> some View {
        let rows: [(String, [String])] = [
            ("Commands", review.commands),
            ("Event triggers", review.eventTriggers),
            ("Web UI windows", review.windows),
            ("Named UI actions", review.namedActions),
        ]
        if rows.contains(where: { !$0.1.isEmpty }) {
            reviewSection("Contributions") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(rows, id: \.0) { label, values in
                        if !values.isEmpty {
                            LabeledContent(label) {
                                Text(values.joined(separator: "\n"))
                                    .font(.system(size: 10, design: .monospaced))
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
            }
        }
    }

    private func permissionsSection(_ review: ExtensionBuildReview) -> some View {
        reviewSection("Requested permissions") {
            if review.permissions.isEmpty {
                Text("None").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(review.permissions, id: \.self) { permission in
                        Text(permission)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func problemsSection(_ review: ExtensionBuildReview) -> some View {
        if !review.problems.isEmpty {
            reviewSection("Validation problems") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(review.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func filesSection(_ review: ExtensionBuildReview) -> some View {
        reviewSection("Generated files (\(review.files.count))") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(review.files) { file in
                    DisclosureGroup {
                        if let content = file.content {
                            ScrollView(.horizontal) {
                                Text(content)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(maxHeight: 260)
                            .background(Color.black.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            Text(file.note ?? "Preview unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(file.path).font(.system(size: 11, design: .monospaced))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

    private func reworkSection(_ build: ExtensionBuild) -> some View {
        reviewSection("Request changes") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $feedback)
                    .font(.system(size: 12)).frame(minHeight: 70)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("Send feedback to agent") { sendFeedback(build) }
                        .disabled(working || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func approvalSection(_ build: ExtensionBuild) -> some View {
        let review = builder.review(for: build.extensionId)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("Enabling allows the declared scripts, session actions, events, URLs, notifications, and UI windows to run with your user account.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Approve & Enable") { approve(build) }
                .buttonStyle(.borderedProminent)
                .disabled(working || review?.canApprove != true)
        }
        .padding(12).background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Choose a build or create a new extension.").foregroundStyle(.secondary)
        }
    }

    private func reviewSection<Content: View>(_ title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusMessage(_ text: String) -> some View {
        Label(text, systemImage: text.hasPrefix("✓") ? "checkmark.circle" : "exclamationmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(text.hasPrefix("✓") ? Color.green : Color.orange)
            .textSelection(.enabled)
    }

    private var selectedBuild: ExtensionBuild? {
        guard let selection else { return nil }
        return builder.builds.first { $0.extensionId == selection }
    }

    private func startBuild() {
        let id = extensionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.automaticIdentifier() : extensionId.trimmingCharacters(in: .whitespacesAndNewlines)
        working = true
        message = nil
        Task {
            let result = await builder.create(extensionId: id, goal: goal)
            working = false
            switch result {
            case .success:
                extensionId = ""
                goal = ""
                selection = id
                showingCreate = false
            case .failure(let error): message = error
            }
        }
    }

    private func sendFeedback(_ build: ExtensionBuild) {
        let text = feedback
        working = true
        message = nil
        Task {
            let result = await builder.rework(extensionId: build.extensionId, feedback: text)
            working = false
            switch result {
            case .success:
                feedback = ""
                message = "✓ Feedback sent."
            case .failure(let error): message = error
            }
        }
    }

    private func approve(_ build: ExtensionBuild) {
        working = true
        message = nil
        Task {
            let result = await builder.approve(extensionId: build.extensionId)
            working = false
            switch result {
            case .success: message = "✓ Reviewed extension enabled."
            case .failure(let error): message = error
            }
        }
    }

    private func loadReviewIfNeeded(_ build: ExtensionBuild) {
        if build.status == .needsReview || build.status == .approved,
           builder.review(for: build.extensionId) == nil {
            builder.refreshReview(extensionId: build.extensionId)
        }
    }

    private func reveal(_ id: String) {
        let url = appModel.extensions.revealDirectory().appendingPathComponent(id, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func statusIcon(_ status: ExtensionBuild.Status) -> String {
        switch status {
        case .generating, .reworking: return "sparkles"
        case .needsReview: return "doc.text.magnifyingglass"
        case .approved: return "checkmark.seal.fill"
        }
    }

    private func statusColor(_ status: ExtensionBuild.Status) -> Color {
        switch status {
        case .generating, .reworking: return .purple
        case .needsReview: return .orange
        case .approved: return .green
        }
    }

    private static func automaticIdentifier() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        return "extension-\(formatter.string(from: Date()))"
    }
}

/// Tiny wrapping layout for permission chips; avoids a horizontal scroller for long lists.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
                            subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}
