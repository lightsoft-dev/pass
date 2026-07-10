import XCTest
@testable import Pass

final class GitWorktreeServiceTests: XCTestCase {
    private var repo: String!

    override func setUpWithError() throws {
        // A throwaway git repo with one commit (worktree add needs a HEAD).
        let dir = NSTemporaryDirectory() + "pass-wt-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Canonicalize (/var → /private/var) so paths match what git rev-parse reports.
        repo = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        run(["init", "-q"])
        run(["config", "user.email", "t@t.dev"])
        run(["config", "user.name", "t"])
        run(["config", "commit.gpgsign", "false"])
        try "hi".write(toFile: dir + "/README", atomically: true, encoding: .utf8)
        run(["add", "-A"])
        run(["commit", "-q", "-m", "init"])
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(atPath: repo) }
    }

    func testCreatesWorktreeOnNewBranch() {
        let result = GitWorktreeService.addWorktree(mainRepoRoot: repo, branch: "feat/login")
        guard case .success(let path) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(path, repo + "-feat-login")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/README"))
        // The worktree is on the new branch, grouped under the main repo.
        let id = GitIdentityService.identity(for: path)
        XCTAssertEqual(id?.branch, "feat/login")
        XCTAssertEqual(id?.isLinkedWorktree, true)
        XCTAssertEqual(resolve(id?.projectRoot), resolve(repo)) // git may report /var vs /private/var
    }

    /// Collapse the /var → /private/var symlink so path comparisons are stable across machines.
    private func resolve(_ p: String?) -> String? {
        p.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    func testChecksOutExistingBranch() {
        run(["branch", "existing"])
        let result = GitWorktreeService.addWorktree(mainRepoRoot: repo, branch: "existing")
        guard case .success(let path) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(GitIdentityService.identity(for: path)?.branch, "existing")
    }

    func testDisambiguatesWhenPathTaken() {
        // Occupy the natural sibling path so the service must pick a suffixed one.
        try? FileManager.default.createDirectory(atPath: repo + "-dup", withIntermediateDirectories: true)
        let result = GitWorktreeService.addWorktree(mainRepoRoot: repo, branch: "dup")
        guard case .success(let path) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(path, repo + "-dup-2")
    }

    func testEmptyBranchIsRejected() {
        if case .success = GitWorktreeService.addWorktree(mainRepoRoot: repo, branch: "  ") {
            XCTFail("blank branch should fail")
        }
    }

    private func run(_ args: [String]) {
        _ = Shell.run("/usr/bin/git", ["-C", repo] + args)
    }
}
