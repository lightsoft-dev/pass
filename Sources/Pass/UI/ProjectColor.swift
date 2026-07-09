import SwiftUI
import CryptoKit

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
