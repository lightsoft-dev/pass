import SwiftUI

/// Compact presentation switch shared by the home workspace and full session detail.
struct SessionPresentationPicker: View {
    @Binding var readableMode: Bool
    var onTerminalSelected: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            button(label: "Readable", icon: "text.alignleft", selected: readableMode) {
                readableMode = true
            }
            button(label: "Terminal", icon: "terminal", selected: !readableMode) {
                readableMode = false
                onTerminalSelected?()
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session presentation")
    }

    private func button(
        label: String,
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A reading-first projection of a live agent TUI. It remains a projection—the terminal stays
/// attached in the background and is always one click away for precise keyboard interaction.
struct ConversationPaneView: View {
    let session: Session

    @State private var blocks: [AgentConversationBlock] = []
    @State private var hasCaptured = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if blocks.isEmpty {
                        emptyState
                    } else {
                        ForEach(blocks) { block in
                            ConversationBlockView(block: block, agent: session.agent)
                                .id(block.id)
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .task(id: session.name) {
                while !Task.isCancelled {
                    let pane = await TmuxClient.shared.capturePaneHistory(session.name)
                    let next = AgentConversationParser.parse(pane, agent: session.agent)
                    let previousLast = blocks.last?.id
                    blocks = next
                    hasCaptured = true
                    if previousLast != next.last?.id, let last = next.last?.id {
                        withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(agentAccent)
                .frame(width: 42, height: 3)
            Text(hasCaptured ? "No conversation detected" : "Reading the session…")
                .font(.custom("New York", size: 19).weight(.semibold))
            Text(hasCaptured
                 ? "This provider has not emitted a recognizable message yet. Switch to Terminal for the unfiltered view."
                 : "Recent agent output will be arranged into messages and tool activity.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 36)
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var agentAccent: Color {
        switch session.agent {
        case .claude: return Color(red: 0.79, green: 0.36, blue: 0.22)
        case .codex: return Color(red: 0.16, green: 0.55, blue: 0.42)
        case .pi: return Color(red: 0.31, green: 0.45, blue: 0.78)
        case .shell, .generic: return .secondary
        }
    }
}

private struct ConversationBlockView: View {
    let block: AgentConversationBlock
    let agent: AgentKind

    var body: some View {
        switch block.kind {
        case .user:
            HStack {
                Spacer(minLength: 72)
                Text(markdown(block.text))
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                    }
            }
        case .assistant:
            HStack(alignment: .top, spacing: 13) {
                Text(agent.glyph)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 20, height: 20)
                    .background(accent.opacity(0.1), in: Circle())
                    .accessibilityHidden(true)
                Text(markdown(block.text))
                    .font(.custom("New York", size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tool:
            ToolConversationBlock(block: block, accent: accent)
        case .output:
            Text(block.text)
                .font(.custom("SF Mono", size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var accent: Color {
        switch agent {
        case .claude: return Color(red: 0.79, green: 0.36, blue: 0.22)
        case .codex: return Color(red: 0.16, green: 0.55, blue: 0.42)
        case .pi: return Color(red: 0.31, green: 0.45, blue: 0.78)
        case .shell, .generic: return .secondary
        }
    }

    private func markdown(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }
}

private struct ToolConversationBlock: View {
    let block: AgentConversationBlock
    let accent: Color
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 22, height: 22)
                        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.title ?? "Tool output")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !expanded, let summary = block.text.split(separator: "\n").first {
                            Text(summary)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            if expanded, !block.text.isEmpty {
                ScrollView(.horizontal) {
                    Text(block.text)
                        .font(.custom("SF Mono", size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 32)
            }
        }
    }
}
