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

    @MainActor
    func testHidingPanelPreservesAndRestoresAllProjectShells() {
        var windows: [MiniTerminalWindowSpy] = []
        let manager = MiniTerminalManager { _, onClose in
            let window = MiniTerminalWindowSpy(onClose: onClose)
            windows.append(window)
            return window
        }
        let project = session(name: "pass-project", cwd: "/projects/project")
        manager.open(for: project)
        manager.openNew(for: project)
        manager.run("export TEST_VALUE=kept", for: project)
        windows[1].isKey = true
        XCTAssertTrue(manager.isKey)

        manager.setPanelVisible(false)

        XCTAssertTrue(windows.allSatisfy { !$0.isVisible })
        XCTAssertFalse(manager.isKey)
        XCTAssertTrue(windows.allSatisfy { $0.closeCount == 0 })
        XCTAssertEqual(windows[1].commands, ["export TEST_VALUE=kept"])

        manager.setPanelVisible(true)

        XCTAssertEqual(windows.count, 2, "Restoring Pass must reuse both PTYs")
        XCTAssertTrue(windows.allSatisfy(\.isVisible))
        XCTAssertFalse(manager.isKey, "Restoring windows must leave keyboard focus in Pass")
        XCTAssertTrue(windows.allSatisfy { $0.closeCount == 0 })
        XCTAssertEqual(windows[1].commands, ["export TEST_VALUE=kept"])
    }

    @MainActor
    func testHiddenSessionChangesRestoreOnlyTheSelectedProjectsWindows() {
        var windows: [String: [MiniTerminalWindowSpy]] = [:]
        let manager = MiniTerminalManager { session, _ in
            let window = MiniTerminalWindowSpy()
            windows[session.cwd, default: []].append(window)
            return window
        }
        let first = session(name: "pass-first", cwd: "/projects/first")
        let second = session(name: "pass-second", cwd: "/projects/second")
        manager.open(for: first)
        manager.openNew(for: first)
        manager.open(for: second)
        manager.setPanelVisible(false)

        manager.activate(for: first)
        XCTAssertTrue(windows.values.flatMap { $0 }.allSatisfy { !$0.isVisible })

        manager.setPanelVisible(true)
        XCTAssertTrue(windows[first.cwd]!.allSatisfy(\.isVisible))
        XCTAssertTrue(windows[second.cwd]!.allSatisfy { !$0.isVisible })
    }

    @MainActor
    func testNewWindowsAreIndependentAndOpenReusesTheLatestShell() {
        var windows: [MiniTerminalWindowSpy] = []
        let manager = MiniTerminalManager { _, onClose in
            let window = MiniTerminalWindowSpy(onClose: onClose)
            windows.append(window)
            return window
        }
        let project = session(name: "pass-project", cwd: "/projects/project")
        manager.open(for: project)
        manager.openNew(for: project)
        manager.open(for: project)
        manager.run("pwd", for: project)

        XCTAssertEqual(windows.count, 2)
        XCTAssertTrue(windows.allSatisfy(\.isVisible))
        XCTAssertTrue(windows[0].commands.isEmpty)
        XCTAssertEqual(windows[1].commands, ["pwd"])

        windows[1].close()
        manager.run("echo still-running", for: project)
        XCTAssertEqual(windows.count, 2, "Closing one window must keep the other shell")
        XCTAssertEqual(windows[0].commands, ["echo still-running"])
        XCTAssertEqual(windows[0].closeCount, 0)

        manager.closeAll()
        XCTAssertEqual(windows.map(\.closeCount), [1, 1])
    }

    @MainActor
    func testClosingLastWindowAllowsANewShellInTheSameDirectory() {
        var windows: [MiniTerminalWindowSpy] = []
        let manager = MiniTerminalManager { _, onClose in
            let window = MiniTerminalWindowSpy(onClose: onClose)
            windows.append(window)
            return window
        }
        let project = session(name: "pass-project", cwd: "/projects/project")
        manager.open(for: project)
        windows[0].close()
        manager.open(for: project)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].closeCount, 1)
        XCTAssertTrue(windows[1].isVisible)
    }

    @MainActor
    func testSessionChangeWhilePanelIsHiddenCannotExposeNewWindows() {
        var windows: [MiniTerminalWindowSpy] = []
        let manager = MiniTerminalManager { _, _ in
            let window = MiniTerminalWindowSpy()
            windows.append(window)
            return window
        }
        let project = session(name: "pass-project", cwd: "/projects/project")
        manager.setPanelVisible(false)
        manager.openNew(for: project)
        manager.run("pwd", for: project)
        manager.activate(for: project)
        XCTAssertEqual(windows.count, 1)
        XCTAssertFalse(windows[0].isVisible)
        XCTAssertEqual(windows[0].commands, ["pwd"])

        manager.setPanelVisible(true)
        XCTAssertTrue(windows[0].isVisible)
        XCTAssertEqual(windows[0].closeCount, 0)
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
    private(set) var closeCount = 0
    var isKey = false
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    func show() { isVisible = true }
    func showForActiveSession() { isVisible = true }
    func hideForInactiveSession() { isVisible = false; isKey = false }
    func run(_ command: String) { commands.append(command) }
    func close() {
        isVisible = false
        isKey = false
        closeCount += 1
        onClose()
    }
}
