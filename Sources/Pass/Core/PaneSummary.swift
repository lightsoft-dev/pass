import Foundation

/// Pulls a "what's it doing right now" one-liner out of a streaming agent's pane — the last
/// meaningful content line, skipping the input box, horizontal rules, and status bar chrome.
enum PaneSummary {
    static func lastContentLine(_ pane: String) -> String? {
        let lines = pane.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for raw in lines.reversed() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if isChrome(t) { continue }
            return collapse(t)
        }
        return nil
    }

    /// TUI decoration that isn't the agent's actual output.
    private static func isChrome(_ t: String) -> Bool {
        // Horizontal rules (─, ╌, -) of any length.
        if t.allSatisfy({ $0 == "─" || $0 == "╌" || $0 == "-" || $0 == "═" }) { return true }
        // Input box prompt line.
        if t.hasPrefix("❯") { return true }
        // Status bar: "branch | /path | Context: N% used", "← for agents", slash hints.
        if t.contains(" | ") && (t.contains("Context") || t.contains("used")) { return true }
        if t.hasPrefix("←") || t.hasPrefix("↑") { return true }
        if t.hasPrefix("/") && t.count <= 8 { return true }        // "/rc", "/effort"
        if t.contains("for agents") || t.contains("to edit in") { return true }
        return false
    }

    private static func collapse(_ t: String) -> String {
        // Strip the leading assistant/spinner glyphs so the text reads cleanly in a small row.
        var s = t
        for glyph in ["⏺ ", "✻ ", "✶ ", "✽ ", "· ", "⎿ ", "  ⎿ "] {
            if s.hasPrefix(glyph) { s = String(s.dropFirst(glyph.count)); break }
        }
        return s.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
