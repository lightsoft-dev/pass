import XCTest
@testable import Pass

final class ReplyInjectorTests: XCTestCase {
    func testDecisionRefusesBareShellWithoutTyping() async {
        let tmux = FakeReplyInjectorTmux(states: [(false, "zsh")])
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendDecision("pass-app", agent: .claude, .allowOnce)
        let sentKeys = await tmux.sentKeys

        XCTAssertEqual(result, .refusedShell)
        XCTAssertEqual(sentKeys, [])
    }

    func testDecisionRequiresVisiblePermissionDialog() async {
        let tmux = FakeReplyInjectorTmux(states: [(false, "claude")], pane: "Claude is ready\n❯")
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendDecision("pass-app", agent: .claude, .deny)
        let sentKeys = await tmux.sentKeys

        XCTAssertEqual(result, .error("permission prompt is no longer active"))
        XCTAssertEqual(sentKeys, [])
    }

    func testDecisionCancelsCopyModeThenRechecksAndDelivers() async {
        let pane = """
        Do you want to create file.txt?
        ❯ 1. Yes
          2. Yes, allow all edits
          3. No
        Esc to cancel
        """
        let tmux = FakeReplyInjectorTmux(
            states: [(true, "claude"), (false, "claude")],
            pane: pane
        )
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendDecision("pass-app", agent: .claude, .allowAll)
        let cancelCount = await tmux.cancelCount
        let sentKeys = await tmux.sentKeys

        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(sentKeys, [["2"]])
    }

    func testSendTextReportsSetBufferFailureWithoutContinuing() async {
        let tmux = FakeReplyInjectorTmux(
            states: [(false, "claude")],
            setBufferSucceeds: false
        )
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendText("pass-app", agent: .claude, text: "Run tests")
        let pasteCount = await tmux.pasteCount
        let sentKeys = await tmux.sentKeys

        XCTAssertEqual(result, .error("tmux could not stage the message"))
        XCTAssertEqual(pasteCount, 0)
        XCTAssertEqual(sentKeys, [])
    }

    func testSendTextReportsPasteFailureWithoutSubmitting() async {
        let tmux = FakeReplyInjectorTmux(
            states: [(false, "claude")],
            pasteBufferSucceeds: false
        )
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendText("pass-app", agent: .claude, text: "Run tests")
        let pasteCount = await tmux.pasteCount
        let sentKeys = await tmux.sentKeys

        XCTAssertEqual(result, .error("tmux could not paste the message into the session"))
        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(sentKeys, [])
    }

    func testSendTextReportsSubmitFailureInsteadOfDelivery() async {
        let tmux = FakeReplyInjectorTmux(
            states: [(false, "claude")],
            sendKeysSucceeds: false
        )
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendText("pass-app", agent: .claude, text: "Run tests")
        let sentKeys = await tmux.sentKeys

        XCTAssertEqual(result, .error("tmux could not submit the message"))
        XCTAssertEqual(sentKeys, [["Enter"]])
    }

    func testDecisionReportsSendKeysFailure() async {
        let pane = "Do you want to create file.txt?  ❯ 1. Yes  2. Allow  3. No  Esc to cancel"
        let tmux = FakeReplyInjectorTmux(
            states: [(false, "claude")],
            pane: pane,
            sendKeysSucceeds: false
        )
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendDecision("pass-app", agent: .claude, .deny)
        let sentKeys = await tmux.sentKeys

        XCTAssertEqual(result, .error("tmux could not submit the decision"))
        XCTAssertEqual(sentKeys, [["3"]])
    }
}

private actor FakeReplyInjectorTmux: ReplyInjectorTmux {
    private var states: [(inMode: Bool, command: String)]
    private let pane: String
    private let setBufferSucceeds: Bool
    private let pasteBufferSucceeds: Bool
    private let sendKeysSucceeds: Bool
    private(set) var sentKeys: [[String]] = []
    private(set) var cancelCount = 0
    private(set) var pasteCount = 0

    init(
        states: [(Bool, String)],
        pane: String = "",
        setBufferSucceeds: Bool = true,
        pasteBufferSucceeds: Bool = true,
        sendKeysSucceeds: Bool = true
    ) {
        self.states = states.map { (inMode: $0.0, command: $0.1) }
        self.pane = pane
        self.setBufferSucceeds = setBufferSucceeds
        self.pasteBufferSucceeds = pasteBufferSucceeds
        self.sendKeysSucceeds = sendKeysSucceeds
    }

    func paneState(_ name: String) -> (inMode: Bool, command: String) {
        if states.count > 1 { return states.removeFirst() }
        return states.first ?? (false, "zsh")
    }

    func capturePane(_ name: String, colors: Bool) -> String { pane }

    func cancelMode(_ name: String) {
        cancelCount += 1
    }

    func setBuffer(_ text: String) -> Bool { setBufferSucceeds }

    func pasteBuffer(into name: String) -> Bool {
        pasteCount += 1
        return pasteBufferSucceeds
    }

    func sendKeys(_ name: String, _ keys: [String]) -> Bool {
        sentKeys.append(keys)
        return sendKeysSucceeds
    }
}
