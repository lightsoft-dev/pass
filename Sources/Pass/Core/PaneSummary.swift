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

    /// The last up-to-`max` meaningful lines, in on-screen (top→bottom) order, joined by newline.
    /// Used as a last-resort card fallback when a session has no recorded response yet.
    static func lastContentLines(_ pane: String, max: Int = 2) -> String? {
        let lines = pane.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var picked: [String] = []
        for raw in lines.reversed() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if isChrome(t) { continue }
            picked.append(collapse(t))
            if picked.count >= max { break }
        }
        return picked.isEmpty ? nil : picked.reversed().joined(separator: "\n")
    }

    /// The agent's last *prose* message on screen — the text of the last `⏺` block that isn't a
    /// tool invocation (`⏺ Bash(...)`, `⏺ Read(...)` are skipped). Claude Code prefixes each
    /// assistant turn with `⏺` and wraps continuation lines indented two spaces. Falls back to
    /// nil when no such block is visible (message scrolled off / only tool calls shown), so the
    /// caller can drop to `lastContentLines`.
    static func lastAgentMessage(_ pane: String) -> String? {
        let lines = pane.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Find the last assistant bullet that carries prose (not a tool call).
        var start: Int?
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("⏺") else { continue }
            let content = collapse(t)
            if content.isEmpty || isToolCall(content) { continue }
            start = i
            break
        }
        guard let start else { return nil }

        // Gather that line plus its indented continuation lines (a wrapped paragraph), stopping
        // at a blank line, the next bullet, a tool-result marker, or status chrome.
        var out = [collapse(lines[start].trimmingCharacters(in: .whitespaces))]
        var j = start + 1
        while j < lines.count, out.count < 12 {
            let raw = lines[j]
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("⏺") || t.hasPrefix("⎿") || isChrome(t) { break }
            guard raw.hasPrefix("  ") else { break } // continuation lines are indented
            out.append(collapse(t))
            j += 1
        }
        return out.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A `⏺` line that's a tool call, e.g. "Bash(ls)", "Read(x.txt)" — a capitalized identifier
    /// immediately followed by '(' (glyph already stripped).
    private static func isToolCall(_ s: String) -> Bool {
        guard let paren = s.firstIndex(of: "(") else { return false }
        let name = s[s.startIndex..<paren]
        guard let first = name.first, first.isUppercase else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
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
