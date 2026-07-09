import SwiftUI
import CryptoKit

/// Leading indicator on a session card: the project's assigned emoji if set, otherwise the
/// deterministic project-color dot.
struct SessionBadge: View {
    let session: Session
    var size: CGFloat = 12

    var body: some View {
        if let emoji = session.emoji, !emoji.isEmpty {
            Text(emoji).font(.system(size: size))
        } else {
            Circle().fill(ProjectColor.color(for: session.projectRoot))
                .frame(width: max(7, size * 0.6), height: max(7, size * 0.6))
        }
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
