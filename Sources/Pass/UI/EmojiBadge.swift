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

/// The SYSTEM emoji picker, not a bundled list: a tiny input field the macOS character
/// palette types into. The palette (the ⌃⌘Space picker — full catalog, search, skin tones,
/// recents) opens automatically; the first emoji that lands in the field is assigned.
private struct EmojiPickerPopover: View {
    let current: String
    let onPick: (String?) -> Void
    let onClose: () -> Void

    @State private var input: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            TextField(current.isEmpty ? "🙂" : current, text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 20))
                .multilineTextAlignment(.center)
                .frame(width: 110)
                .focused($focused)
                .onChange(of: input) { _, new in
                    if let emoji = new.first(where: \.isEmojiLike) {
                        onPick(String(emoji))
                        onClose()
                    } else if !new.isEmpty {
                        input = "" // non-emoji keystrokes — keep the field clean
                    }
                }
            Text("pick from the system palette, or type one")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Button("Open palette") { openPalette() }.controlSize(.small)
                Button("Remove", role: .destructive) { onPick(nil); onClose() }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .onAppear {
            focused = true
            // Summon the palette once the field really holds first-responder status —
            // the palette inserts into whatever is focused at that moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { openPalette() }
        }
    }

    private func openPalette() {
        NSApp.activate(ignoringOtherApps: true) // accessory app: palette needs us active
        NSApp.orderFrontCharacterPalette(nil)
    }
}

private extension Character {
    /// A grapheme that renders as emoji — excludes plain digits/#/* (technically Emoji=Yes)
    /// so stray typing doesn't get assigned. Covers ZWJ families, flags, and ️-variants.
    var isEmojiLike: Bool {
        guard let first = unicodeScalars.first else { return false }
        return unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || unicodeScalars.contains { $0.value == 0xFE0F } // text symbol + emoji variation
            || (first.properties.isEmoji && first.value >= 0x1F000)
    }
}
