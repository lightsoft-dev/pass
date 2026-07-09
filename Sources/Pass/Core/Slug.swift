import Foundation

enum Slug {
    /// tmux session names cannot contain '.' or ':' and shouldn't contain whitespace.
    /// Map anything else that's awkward to '-'.
    static func make(_ s: String) -> String {
        let mapped = s.lowercased().map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "-"
        }
        var out = String(mapped)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Session name for a project dir + optional branch:
    ///   pass-<repo>            (main checkout / default branch)
    ///   pass-<repo>--<branch>  (specific branch / worktree)
    static func sessionName(repo: String, branch: String?) -> String {
        var name = PassConfig.sessionPrefix + make(repo)
        if let branch, !branch.isEmpty {
            name += "--" + make(branch)
        }
        return name
    }
}
