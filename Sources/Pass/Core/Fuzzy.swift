import Foundation

enum Fuzzy {
    /// Case-insensitive subsequence match (fzf-style). Returns nil if no match, else a
    /// score (lower = better: prefers contiguous, early matches).
    static func score(_ needle: String, _ haystack: String) -> Int? {
        if needle.isEmpty { return 0 }
        let n = Array(needle.lowercased())
        let h = Array(haystack.lowercased())
        var ni = 0
        var score = 0
        var lastMatch = -1
        for (hi, hc) in h.enumerated() {
            if ni < n.count && hc == n[ni] {
                if lastMatch >= 0 { score += (hi - lastMatch - 1) } // gap penalty
                else { score += hi }                                 // leading offset
                lastMatch = hi
                ni += 1
            }
        }
        return ni == n.count ? score : nil
    }

    static func matches(_ needle: String, _ haystack: String) -> Bool {
        score(needle, haystack) != nil
    }
}
