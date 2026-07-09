import Foundation

/// One selectable option from an agent's numbered prompt (permission dialog, AskUserQuestion,
/// etc.), parsed out of the visible pane.
struct DecisionOption: Identifiable, Equatable, Sendable {
    let number: Int
    let label: String
    let highlighted: Bool // the `❯`-marked current choice
    var id: Int { number }
}

/// Pulls a numbered choice list out of capture-pane text. The option labels live only on the
/// TUI screen (the hook payload just says "needs your permission"), so we scrape them so the
/// user can pick from the home card without opening the terminal.
enum DecisionParser {
    static func parse(_ pane: String) -> [DecisionOption] {
        var found: [DecisionOption] = []
        for rawLine in pane.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let highlighted = line.contains("❯")
            let cleaned = line
                .replacingOccurrences(of: "❯", with: " ")
                .trimmingCharacters(in: .whitespaces)
            // Match "N. label" at the start of the (marker-stripped) line.
            guard let dot = cleaned.firstIndex(of: "."), dot != cleaned.startIndex else { continue }
            let numStr = cleaned[cleaned.startIndex..<dot]
            guard let num = Int(numStr), (1...20).contains(num) else { continue }
            let label = String(cleaned[cleaned.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            found.append(DecisionOption(number: num, label: label, highlighted: highlighted))
        }

        // Keep the first occurrence per number, require a consecutive 1..N run of ≥2 — that's
        // what distinguishes a real choice menu from a stray "1. foo" inside prose.
        var seen = Set<Int>()
        let unique = found.filter { seen.insert($0.number).inserted }.sorted { $0.number < $1.number }
        guard unique.count >= 2 else { return [] }
        for (i, opt) in unique.enumerated() where opt.number != i + 1 { return [] }
        return unique
    }
}
