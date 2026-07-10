import Foundation

/// Creates git worktrees for `+branch` sessions by shelling out to `git worktree add`.
/// The worktree lives as a sibling of the main checkout: `<mainRepoRoot>-<branch-slug>`.
enum GitWorktreeService {
    private static let gitPath: String = Shell.resolveViaLoginShell("git") ?? "/usr/bin/git"

    enum Failure: Error {
        case badBranch
        case git(String)

        /// Short, user-facing message (last line of git's stderr, which is the actual reason).
        var message: String {
            switch self {
            case .badBranch: return "invalid branch name"
            case .git(let stderr):
                let last = stderr.split(separator: "\n").last.map(String.init) ?? stderr
                let trimmed = last.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? "git worktree add failed" : trimmed
            }
        }
    }

    /// Create a worktree for `branch` off `mainRepoRoot`: a brand-new branch if it doesn't
    /// exist, otherwise a checkout of the existing branch. Returns the worktree's absolute path.
    static func addWorktree(mainRepoRoot: String, branch: String) -> Result<String, Failure> {
        let slug = Slug.make(branch)
        guard !slug.isEmpty else { return .failure(.badBranch) }

        // Sibling path; disambiguate if something already occupies it.
        let base = mainRepoRoot + "-" + slug
        var path = base
        var n = 2
        while FileManager.default.fileExists(atPath: path) {
            path = "\(base)-\(n)"
            n += 1
        }

        // Prefer creating a fresh branch; if it already exists, check it out into the worktree.
        var r = Shell.run(gitPath, ["-C", mainRepoRoot, "worktree", "add", path, "-b", branch])
        if !r.ok {
            r = Shell.run(gitPath, ["-C", mainRepoRoot, "worktree", "add", path, branch])
        }
        guard r.ok else { return .failure(.git(r.stderr)) }
        return .success(path)
    }
}
