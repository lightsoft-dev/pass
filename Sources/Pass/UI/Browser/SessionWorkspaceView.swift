import SwiftUI

/// A session's workspace: its terminal, plus — when the session has a visible browser tab —
/// the browser pane in a draggable split beside it (⌘⇧B expands the browser full-width).
/// Wraps every place a terminal renders (home stack card, list/sidebar panel, detail view)
/// so the browser follows the session everywhere. With no tab it IS the terminal — zero cost.
struct SessionWorkspaceView<Terminal: View>: View {
    let session: Session
    let terminal: Terminal

    @Environment(AppModel.self) private var appModel
    /// Browser's share of the width (0.2…0.8), persisted like the panel size.
    @AppStorage("browser.split") private var browserFraction = 0.45

    init(session: Session, @ViewBuilder terminal: () -> Terminal) {
        self.session = session
        self.terminal = terminal()
    }

    private var tab: BrowserTab? { appModel.browser?.visibleTab(for: session.name) }

    var body: some View {
        if let tab {
            if appModel.browser?.expanded == true {
                BrowserPaneView(tab: tab).id(tab.id)
            } else {
                split(tab)
            }
        } else {
            terminal
        }
    }

    private func split(_ tab: BrowserTab) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                terminal
                    .frame(width: terminalWidth(total: geo.size.width))
                divider(total: geo.size.width)
                BrowserPaneView(tab: tab)
                    .id(tab.id) // different tab → fresh NSView (updateNSView can't swap it)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: "workspace")
        }
    }

    private func terminalWidth(total: CGFloat) -> CGFloat {
        max(120, total * (1 - browserFraction) - dividerWidth)
    }

    private let dividerWidth: CGFloat = 7

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(width: dividerWidth)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 2, height: 28)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("workspace"))
                    .onChanged { value in
                        guard total > 0 else { return }
                        browserFraction = min(0.8, max(0.2, 1 - value.location.x / total))
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}
