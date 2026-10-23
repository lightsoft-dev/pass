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

    func testTextRefusesVisiblePermissionPromptWithoutPasting() async {
        let pane = "Do you want to run this command?\n❯ 1. Yes\n  2. Always allow\n  3. No\nEsc to cancel"
        let tmux = FakeReplyInjectorTmux(states: [(false, "claude")], pane: pane)
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendText("pass-app", agent: .claude, text: "yes")
        let pasteCount = await tmux.pasteCount
        let sentKeys = await tmux.sentKeys

        XCTAssertEqual(result, .error("permission prompt needs a decision, not a text message"))
        XCTAssertEqual(pasteCount, 0)
        XCTAssertEqual(sentKeys, [])
    }

    func testTextRechecksPermissionPromptAfterLeavingCopyMode() async {
        let pane = "Do you want to run this command?\n❯ 1. Yes\n  2. Always allow\n  3. No\nEsc to cancel"
        let tmux = FakeReplyInjectorTmux(
            states: [(true, "claude"), (false, "claude")], pane: pane
        )
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendText("pass-app", agent: .claude, text: "yes")
        let cancelCount = await tmux.cancelCount
        let pasteCount = await tmux.pasteCount

        XCTAssertEqual(result, .error("permission prompt needs a decision, not a text message"))
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(pasteCount, 0)
    }

    func testPickRejectsChoiceMissingFromVisiblePrompt() async {
        let pane = "Which option?\n❯ 1. Keep current\n  2. Change it"
        let tmux = FakeReplyInjectorTmux(states: [(false, "claude")], pane: pane)
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.pick("pass-app", agent: .claude, option: 3)
        let sentKeys = await tmux.sentKeys

        XCTAssertEqual(result, .error("selected option is no longer visible"))
        XCTAssertEqual(sentKeys, [])
    }

    func testExistingWorkerStaysOnResolvedPaneThroughPasteAndSubmit() async {
        let tmux = FakeReplyInjectorTmux(states: [(false, "claude")], paneTarget: "%49")
        let injector = ReplyInjector(tmux: tmux)

        let result = await injector.sendText("pass-worker", agent: .claude, text: "Continue work")
        let resolved = await tmux.resolvedTargets
        let observed = await tmux.observedTargets
        let pasted = await tmux.pastedTargets
        let submitted = await tmux.sentKeyTargets

        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(resolved, ["pass-worker"])
        XCTAssertEqual(observed, ["%49", "%49"])
        XCTAssertEqual(pasted, ["%49"])
        XCTAssertEqual(submitted, ["%49"])
    }

    func testWorkerPaneSelectionPrefersMainAgentPaneOverNarrowActivePane() {
        let panes = [
            WorkerPaneCandidate(line: "%43\t1\t4\t42\tclaude.exe")!,
            WorkerPaneCandidate(line: "%49\t0\t61\t42\tclaude.exe")!,
        ]

        XCTAssertEqual(WorkerPaneCandidate.select(panes, agent: .claude)?.id, "%49")
    }

    func testWorkerPaneSelectionPrefersExpectedAgentOverLargerOtherPane() {
        let panes = [
            WorkerPaneCandidate(line: "%1\t1\t100\t40\tpi")!,
            WorkerPaneCandidate(line: "%2\t0\t60\t40\tclaude.exe")!,
        ]

        XCTAssertEqual(WorkerPaneCandidate.select(panes, agent: .claude)?.id, "%2")
    }
}

private actor FakeReplyInjectorTmux: ReplyInjectorTmux {
    private var states: [(inMode: Bool, command: String)]
    private let pane: String
    private let paneTarget: String?
    private let setBufferSucceeds: Bool
    private let pasteBufferSucceeds: Bool
    private let sendKeysSucceeds: Bool
    private(set) var sentKeys: [[String]] = []
    private(set) var cancelCount = 0
    private(set) var pasteCount = 0
    private(set) var resolvedTargets: [String] = []
    private(set) var observedTargets: [String] = []
    private(set) var pastedTargets: [String] = []
    private(set) var sentKeyTargets: [String] = []

    init(
        states: [(Bool, String)],
        pane: String = "",
        paneTarget: String? = "pass-app",
        setBufferSucceeds: Bool = true,
        pasteBufferSucceeds: Bool = true,
        sendKeysSucceeds: Bool = true
    ) {
        self.states = states.map { (inMode: $0.0, command: $0.1) }
        self.pane = pane
        self.paneTarget = paneTarget
        self.setBufferSucceeds = setBufferSucceeds
        self.pasteBufferSucceeds = pasteBufferSucceeds
        self.sendKeysSucceeds = sendKeysSucceeds
    }

    func workerPaneTarget(_ name: String, agent: AgentKind?) -> String? {
        resolvedTargets.append(name)
        return paneTarget
    }

    func paneState(_ name: String) -> (inMode: Bool, command: String) {
        observedTargets.append(name)
        if states.count > 1 { return states.removeFirst() }
        return states.first ?? (false, "zsh")
    }

    func capturePane(_ name: String, colors: Bool) -> String {
        observedTargets.append(name)
        return pane
    }

    func cancelMode(_ name: String) {
        cancelCount += 1
    }

    func paste(_ text: String, into name: String) -> TmuxPasteResult {
        pastedTargets.append(name)
        guard setBufferSucceeds else { return .stagingFailed }
        pasteCount += 1
        return pasteBufferSucceeds ? .pasted : .pasteFailed
    }

    func sendKeys(_ name: String, _ keys: [String]) -> Bool {
        sentKeyTargets.append(name)
        sentKeys.append(keys)
        return sendKeysSucceeds
    }
}
