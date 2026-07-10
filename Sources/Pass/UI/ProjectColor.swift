import SwiftUI
import CryptoKit

/// Leading indicator on a session card: the project's assigned emoji if set, otherwise the
/// deterministic project-color dot. Takes emoji/root explicitly so callers can feed a live
/// value from the store (instant update) rather than the reconcile snapshot on the session.
struct SessionBadge: View {
    let emoji: String?
    let projectRoot: String
    var size: CGFloat = 12

    init(emoji: String?, projectRoot: String, size: CGFloat = 12) {
        self.emoji = emoji
        self.projectRoot = projectRoot
        self.size = size
    }

    init(session: Session, size: CGFloat = 12) {
        self.init(emoji: session.emoji, projectRoot: session.projectRoot, size: size)
    }

    var body: some View {
        if let emoji, !emoji.isEmpty {
            Text(emoji).font(.system(size: size))
        } else {
            Circle().fill(ProjectColor.color(for: projectRoot))
                .frame(width: max(7, size * 0.6), height: max(7, size * 0.6))
        }
    }
}

/// Small dimmed pill showing which agent runs a session (glyph + name). Sits below the
/// session's summary — replaces the bare glyph that used to sit next to the title.
struct AgentTag: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 3) {
            Text(agent.glyph)
            Text(agent.rawValue)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
    }
}

/// Deterministic color per project root path — same repo, same hue, forever, across
/// restarts (derived, never stored). Worktrees of a repo share the base hue.
enum ProjectColor {
    private static let hues: [Double] = [
        0.00, 0.08, 0.13, 0.33, 0.47, 0.55, 0.62, 0.80, // 8 high-contrast hues
    ]

    static func color(for projectRoot: String) -> Color {
        let digest = Array(Insecure.MD5.hash(data: Data(projectRoot.utf8)))
        let byte = digest.first ?? 0
        let hue = hues[Int(byte) % hues.count]
        return Color(hue: hue, saturation: 0.65, brightness: 0.95)
    }
}
