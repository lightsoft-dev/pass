import XCTest
@testable import Pass

final class SlugTests: XCTestCase {
    func testBasicSlug() {
        XCTAssertEqual(Slug.make("MyRepo"), "myrepo")
        XCTAssertEqual(Slug.make("feat/stripe-checkout"), "feat-stripe-checkout")
        XCTAssertEqual(Slug.make("a  b..c"), "a-b-c")
        XCTAssertEqual(Slug.make("--edge--"), "edge")
    }

    func testSessionName() {
        XCTAssertEqual(Slug.sessionName(repo: "pass", branch: nil), "pass-pass")
        XCTAssertEqual(Slug.sessionName(repo: "pass", branch: "feat/inbox"), "pass-pass--feat-inbox")
        // '.' and ':' are illegal in tmux session names — must be gone.
        let n = Slug.sessionName(repo: "my.app", branch: "release:2.0")
        XCTAssertFalse(n.contains("."))
        XCTAssertFalse(n.contains(":"))
    }
}

final class AgentKindTests: XCTestCase {
    func testInferFromPaneCommand() {
        XCTAssertEqual(AgentKind.infer(fromPaneCommand: "claude.exe"), .claude)
        XCTAssertEqual(AgentKind.infer(fromPaneCommand: "claude"), .claude)
        XCTAssertEqual(AgentKind.infer(fromPaneCommand: "codex"), .codex)
        XCTAssertEqual(AgentKind.infer(fromPaneCommand: "pi"), .pi)
        XCTAssertEqual(AgentKind.infer(fromPaneCommand: "zsh"), .shell)
        XCTAssertEqual(AgentKind.infer(fromPaneCommand: "-zsh"), .shell)
        XCTAssertEqual(AgentKind.infer(fromPaneCommand: "vim"), .generic)
    }

    func testGlyphsDistinct() {
        let glyphs = AgentKind.allCases.map(\.glyph)
        XCTAssertEqual(Set(glyphs).count, glyphs.count)
    }
}

final class SessionDisplayTests: XCTestCase {
    func testDisplayNameWorktree() {
        let git = GitIdentity(root: "/repos/app-hotfix", branch: "fix/panel",
                              detachedSha: nil, isLinkedWorktree: true,
                              mainRepoRoot: "/repos/app", worktreeDirName: "app-hotfix")
        let s = Session(name: "pass-app--fix-panel", projectRoot: "/repos/app",
                        cwd: "/repos/app-hotfix", agent: .claude, git: git,
                        lastActivity: .init(), isAttached: false)
        XCTAssertEqual(s.displayName, "app ⧉ app-hotfix · fix/panel")
    }

    func testDisplayNameDetached() {
        let git = GitIdentity(root: "/repos/app", branch: nil, detachedSha: "a1b2c3d",
                              isLinkedWorktree: false, mainRepoRoot: nil, worktreeDirName: nil)
        let s = Session(name: "pass-app", projectRoot: "/repos/app", cwd: "/repos/app",
                        agent: .claude, git: git, lastActivity: .init(), isAttached: false)
        XCTAssertEqual(s.displayName, "app · a1b2c3d (detached)")
    }
}
