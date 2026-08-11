import XCTest
@testable import Pass

final class MiniTerminalManagerTests: XCTestCase {
    @MainActor
    func testVisibilityFollowsTheSelectedProject() {
        var windows: [String: MiniTerminalWindowSpy] = [:]
        let manager = MiniTerminalManager { session, _ in
            let window = MiniTerminalWindowSpy()
            windows[session.cwd] = window
            return window
        }
        let first = session(name: "pass-first", cwd: "/projects/first")
        let second = session(name: "pass-second", cwd: "/projects/second")

        manager.activate(for: first)
        manager.open(for: first)
        XCTAssertTrue(windows[first.cwd]?.isVisible == true)

        manager.activate(for: second)
        XCTAssertTrue(windows[first.cwd]?.isVisible == false)
        XCTAssertNil(windows[second.cwd], "An unopened session must not gain a terminal window")

        manager.activate(for: first)
        XCTAssertTrue(windows[first.cwd]?.isVisible == true)
    }

    @MainActor
    func testSessionsInTheSameWorkingDirectoryShareOneTerminal() {
        var created = 0
        let manager = MiniTerminalManager { _, _ in
            created += 1
            return MiniTerminalWindowSpy()
        }
        let first = session(name: "pass-first", cwd: "/projects/shared")
        let second = session(name: "pass-second", cwd: "/projects/shared")

        manager.open(for: first)
        manager.activate(for: second)
        manager.open(for: second)

        XCTAssertEqual(created, 1)
    }

    @MainActor
    func testRunOpensProjectTerminalAndForwardsCommand() {
        var window: MiniTerminalWindowSpy?
        let manager = MiniTerminalManager { _, _ in
            let created = MiniTerminalWindowSpy()
            window = created
            return created
        }
        let project = session(name: "pass-project", cwd: "/projects/project")

        manager.run("swift test", for: project)

        XCTAssertTrue(window?.isVisible == true)
        XCTAssertEqual(window?.commands, ["swift test"])
    }

    private func session(name: String, cwd: String) -> Session {
        Session(
            name: name,
            projectRoot: cwd,
            cwd: cwd,
            agent: .shell,
            git: nil,
            lastActivity: .init(),
            isAttached: false
        )
    }
}

@MainActor
private final class MiniTerminalWindowSpy: MiniTerminalWindowControlling {
    private(set) var isVisible = false
    private(set) var commands: [String] = []

    func show() { isVisible = true }
    func showForActiveSession() { isVisible = true }
    func hideForInactiveSession() { isVisible = false }
    func run(_ command: String) {
        isVisible = true
        commands.append(command)
    }
    func close() { isVisible = false }
}
