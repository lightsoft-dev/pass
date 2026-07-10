import Foundation

/// One selectable option from an agent's numbered prompt (permission dialog, AskUserQuestion,
/// etc.), parsed out of the visible pane.
struct DecisionOption: Identifiable, Equatable, Sendable {
    let number: Int
    let label: String
    let highlighted: Bool // the `❯`-marked current choice
    var id: Int { number }
}

/// Pulls a numbered choice list (and its question text) out of capture-pane text. The labels and
/// the prompt live only on the TUI screen — the hook payload for a permission/elicitation
/// notification carries no body — so we scrape them so the user can read and pick from the home
/// card without opening the terminal.
enum DecisionParser {
    static func parse(_ pane: String) -> [DecisionOption] {
        var found: [DecisionOption] = []
        for rawLine in pane.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let num = optionNumber(line) else { continue }
            found.append(DecisionOption(number: num, label: optionLabel(line), highlighted: line.contains("❯")))
        }

        // Keep the first occurrence per number, require a consecutive 1..N run of ≥2 — that's
        // what distinguishes a real choice menu from a stray "1. foo" inside prose.
        var seen = Set<Int>()
        let unique = found.filter { seen.insert($0.number).inserted }.sorted { $0.number < $1.number }
        guard unique.count >= 2 else { return [] }
        for (i, opt) in unique.enumerated() where opt.number != i + 1 { return [] }
        return unique
    }

    /// The question/context shown above a numbered menu (e.g. "Do you want to create X?") — the
    /// hook payload doesn't carry it, so scrape the lines just above the menu. nil when there's
    /// no valid menu on screen.
    static func prompt(_ pane: String) -> String? {
        let lines = pane.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !parse(pane).isEmpty,
              let oneIdx = lines.lastIndex(where: { optionNumber($0) == 1 }) else { return nil }

        var collected: [String] = []
        var i = oneIdx - 1
        while i >= 0, collected.count < 6 {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)
            if optionNumber(raw) != nil { i -= 1; continue } // skip sibling option lines
            if t.isEmpty { break }                           // blank line = top of the block
            if isBoxBorder(t) { i -= 1; continue }           // skip box-drawing borders
            let cleaned = clean(t)
            if !cleaned.isEmpty { collected.append(cleaned) }
            i -= 1
        }
        let text = collected.reversed().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The option number if `rawLine` is a "N. label" choice (marker/whitespace tolerant), else nil.
    private static func optionNumber(_ rawLine: String) -> Int? {
        let cleaned = rawLine.replacingOccurrences(of: "❯", with: " ").trimmingCharacters(in: .whitespaces)
        guard let dot = cleaned.firstIndex(of: "."), dot != cleaned.startIndex,
              let num = Int(cleaned[cleaned.startIndex..<dot]), (1...20).contains(num) else { return nil }
        let label = cleaned[cleaned.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : num
    }

    private static func optionLabel(_ rawLine: String) -> String {
        let cleaned = rawLine.replacingOccurrences(of: "❯", with: " ").trimmingCharacters(in: .whitespaces)
        guard let dot = cleaned.firstIndex(of: ".") else { return "" }
        return String(cleaned[cleaned.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isBoxBorder(_ t: String) -> Bool {
        !t.isEmpty && t.allSatisfy { "─╌-═╭╮╰╯│┌┐└┘├┤┬┴┼ ".contains($0) }
    }

    /// Strip a leading assistant/prompt glyph and box borders so the question reads cleanly.
    private static func clean(_ t: String) -> String {
        var s = t
        for glyph in ["⏺ ", "✻ ", "> "] where s.hasPrefix(glyph) { s = String(s.dropFirst(glyph.count)); break }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "│ "))
    }
}
