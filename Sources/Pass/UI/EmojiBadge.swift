import SwiftUI

/// The leftmost dot on a home card, made clickable: tap it to set the project's emoji in a
/// small popover. Reads the live emoji from the store so the badge updates the instant you
/// pick one (not on the next reconcile).
struct EmojiBadgeButton: View {
    let session: Session
    var size: CGFloat = 14

    @Environment(AppModel.self) private var appModel
    @State private var show = false
    @State private var hovering = false

    private var liveEmoji: String? { appModel.projects?.emoji(forRoot: session.projectRoot) ?? session.emoji }
    /// A comfortable, easy-to-click tap target around the small badge glyph.
    private var tap: CGFloat { max(26, size + 12) }

    var body: some View {
        Button { show = true } label: {
            SessionBadge(emoji: liveEmoji, projectRoot: session.projectRoot, size: size)
                .frame(width: tap, height: tap)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .overlay(
                    // Hover → a ring so it reads as clickable.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovering ? 0.28 : 0), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Set an emoji for this project")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            EmojiPickerPopover(
                current: liveEmoji ?? "",
                onPick: { appModel.projects?.setEmoji(rootPath: session.projectRoot, $0) },
                onClose: { show = false }
            )
        }
    }
}

/// Slack-style emoji search: type a word (rocket, fire, cat…), pick from the grid. ⏎ picks the
/// first match; the current emoji is highlighted; Remove clears it.
private struct EmojiPickerPopover: View {
    let current: String
    let onPick: (String?) -> Void
    let onClose: () -> Void

    @State private var query: String = ""
    @FocusState private var focused: Bool

    private var results: [String] { EmojiCatalog.search(query) }
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 4), count: 7)

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search emoji — rocket, fire, cat…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { if let first = results.first { commit(first) } }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            if results.isEmpty {
                VStack(spacing: 4) {
                    Text("No matches").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("or press ⌃⌘Space for the system picker")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .frame(height: 200)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(results, id: \.self) { emoji in
                            Button { commit(emoji) } label: {
                                Text(emoji).font(.system(size: 20)).frame(width: 30, height: 30)
                                    .background(emoji == current ? Color.accentColor.opacity(0.25) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                }
                .frame(height: 200)
            }

            Button("Remove emoji", role: .destructive) { onPick(nil); onClose() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(width: 274)
        .onAppear { focused = true }
    }

    private func commit(_ emoji: String) { onPick(emoji); onClose() }
}
