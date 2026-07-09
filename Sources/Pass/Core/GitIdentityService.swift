import Foundation

/// Resolves git identity by shelling out to `git` (correct on every edge case: relative
/// gitdirs, worktrees, detached HEAD). No pure-Swift .git parsing — one subprocess is cheap.
enum GitIdentityService {
    private static let gitPath: String = Shell.resolveViaLoginShell("git") ?? "/usr/bin/git"

    /// Returns nil when `path` is not inside a git repo.
    static func identity(for path: String) -> GitIdentity? {
        // One call: worktree root, branch (or "HEAD" if detached), absolute git dir, short sha.
        let r = Shell.run(gitPath, [
            "-C", path, "rev-parse",
            "--show-toplevel",
            "--abbrev-ref", "HEAD",
            "--absolute-git-dir",
            "--short", "HEAD",
        ])
        guard r.ok else { return nil }
        let lines = r.stdout.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return nil }

        let root = lines[0]
        let branchRaw = lines[1]
        let gitDir = lines[2]
        let shortSha = lines.count >= 4 ? lines[3] : nil

        let detached = (branchRaw == "HEAD")
        let branch = detached ? nil : branchRaw

        // Linked worktree: its git dir lives at <main>/.git/worktrees/<name>.
        var isLinked = false
        var mainRepoRoot: String?
        if let range = gitDir.range(of: "/.git/worktrees/") {
            isLinked = true
            mainRepoRoot = String(gitDir[gitDir.startIndex..<range.lowerBound])
        }

        return GitIdentity(
            root: root,
            branch: branch,
            detachedSha: detached ? shortSha : nil,
            isLinkedWorktree: isLinked,
            mainRepoRoot: mainRepoRoot,
            worktreeDirName: isLinked ? URL(fileURLWithPath: root).lastPathComponent : nil
        )
    }
}
