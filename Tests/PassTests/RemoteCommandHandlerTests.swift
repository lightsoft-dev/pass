import Foundation
import XCTest
@testable import Pass

@MainActor
final class RemoteCommandHandlerTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_752_580_800)

    func testListAlwaysAcknowledgesThenPublishesSnapshot() async {
        let backend = FakeRemoteCommandBackend()
        backend.sessions = [Self.session]
        backend.projects = [.init(rootPath: "/projects/app", name: "app")]
        let handler = makeHandler(backend)

        let events = await handler.handle(command(id: "cmd_list", command: .sessionList))

        XCTAssertEqual(events.map(\.type), [RemoteEventType.acknowledgement, RemoteEventType.sessionSnapshot])
        XCTAssertTrue(events.allSatisfy { $0.replyTo == "cmd_list" })
        guard case .sessionSnapshot(let snapshot) = events[1].event else {
            return XCTFail("Expected snapshot event")
        }
        XCTAssertEqual(snapshot.sessions.map(\.name), ["pass-app"])
        XCTAssertEqual(snapshot.projects.map(\.rootPath), ["/projects/app"])
        XCTAssertTrue(snapshot.capabilities.contains(.decisionsAnswer))
        XCTAssertTrue(snapshot.capabilities.contains(.sessionsTerminal))
    }

    func testCreateRequiresRegisteredProjectAndReturnsCreatedSession() async {
        let backend = FakeRemoteCommandBackend()
        backend.projects = [.init(rootPath: "/projects/app", name: "app")]
        let handler = makeHandler(backend)

        let success = await handler.handle(command(
            id: "cmd_create",
            command: .sessionCreate(.init(projectRoot: "  /projects/app  ", agent: .codex))
        ))

        XCTAssertEqual(success.map(\.type), [RemoteEventType.acknowledgement, RemoteEventType.sessionSnapshot])
        XCTAssertEqual(backend.createdCommands.first?.projectRoot, "/projects/app")
        guard case .acknowledgement(let acknowledgement) = success[0].event else {
            return XCTFail("Expected acknowledgement")
        }
        XCTAssertEqual(acknowledgement.resourceID, "pass-created")

        let failure = await handler.handle(command(
            id: "cmd_bad_project",
            command: .sessionCreate(.init(projectRoot: "/unknown", agent: .claude))
        ))
        XCTAssertEqual(errorCode(failure), "project_not_registered")
    }

    func testCreateFailureReturnsErrorWithoutAcknowledgement() async {
        let backend = FakeRemoteCommandBackend()
        backend.projects = [.init(rootPath: "/projects/app", name: "app")]
        backend.createError = RemoteExecutionError(
            code: "session_create_failed",
            message: "The desktop could not start the requested session.",
            retryable: true
        )
        let handler = makeHandler(backend)

        let events = await handler.handle(command(
            id: "cmd_create_failed",
            command: .sessionCreate(.init(projectRoot: "/projects/app", agent: .claude))
        ))

        XCTAssertEqual(events.map(\.type), [RemoteEventType.error])
        XCTAssertEqual(errorCode(events), "session_create_failed")
        guard case .error(let failure) = events.first?.event else {
            return XCTFail("Expected create failure")
        }
        XCTAssertTrue(failure.retryable)
    }

    func testSendMessageRejectsEmptyTextAndUnknownSession() async {
        let backend = FakeRemoteCommandBackend()
        let handler = makeHandler(backend)

        let empty = await handler.handle(command(
            id: "cmd_empty",
            command: .sessionSendMessage(.init(session: "pass-app", text: "  \n"))
        ))
        XCTAssertEqual(errorCode(empty), "invalid_message")
        XCTAssertTrue(backend.sentCommands.isEmpty)

        let unknown = await handler.handle(command(
            id: "cmd_unknown",
            command: .sessionSendMessage(.init(session: "pass-missing", text: "hello"))
        ))
        XCTAssertEqual(errorCode(unknown), "session_not_found")
    }

    func testSendMessageAcknowledgesDelivery() async {
        let backend = FakeRemoteCommandBackend()
        backend.sessions = [Self.session]
        let handler = makeHandler(backend)

        let events = await handler.handle(command(
            id: "cmd_send",
            command: .sessionSendMessage(.init(session: " pass-app ", text: "hello"))
        ))

        XCTAssertEqual(events.map(\.type), [RemoteEventType.acknowledgement, RemoteEventType.messageDelivered])
        XCTAssertEqual(backend.sentCommands, [.init(session: "pass-app", text: "hello")])
        guard case .messageDelivered(let delivered) = events[1].event else {
            return XCTFail("Expected delivery event")
        }
        XCTAssertEqual(delivered.session, "pass-app")
    }

    func testSendMessageDeliveryFailureNeverEmitsDeliveredEvent() async {
        let backend = FakeRemoteCommandBackend()
        backend.sessions = [Self.session]
        backend.sendError = RemoteExecutionError(
            code: "delivery_failed",
            message: "tmux could not submit the message",
            retryable: true
        )
        let handler = makeHandler(backend)

        let events = await handler.handle(command(
            id: "cmd_send_failed",
            command: .sessionSendMessage(.init(session: "pass-app", text: "hello"))
        ))

        XCTAssertEqual(events.map(\.type), [RemoteEventType.error])
        XCTAssertEqual(errorCode(events), "delivery_failed")
        XCTAssertFalse(events.contains { $0.type == RemoteEventType.messageDelivered })
    }

    func testAnswerDecisionUsesStructuredValuesAndPropagatesNotPending() async {
        let backend = FakeRemoteCommandBackend()
        backend.sessions = [Self.session]
        let handler = makeHandler(backend)

        let success = await handler.handle(command(
            id: "cmd_decide",
            command: .sessionAnswerDecision(.init(session: "pass-app", decision: .deny))
        ))
        XCTAssertEqual(success.map(\.type), [RemoteEventType.acknowledgement, RemoteEventType.sessionSnapshot])
        XCTAssertEqual(backend.decisionCommands, [.init(session: "pass-app", decision: .deny)])

        backend.decisionError = RemoteExecutionError(
            code: "decision_not_pending",
            message: "The session is not waiting on a decision."
        )
        let failure = await handler.handle(command(
            id: "cmd_not_pending",
            command: .sessionAnswerDecision(.init(session: "pass-app", decision: .allowOnce))
        ))
        XCTAssertEqual(errorCode(failure), "decision_not_pending")
    }

    func testTerminalOpenPublishesSnapshotAndInputUsesActiveSubscription() async {
        let backend = FakeRemoteCommandBackend()
        backend.sessions = [Self.session]
        let handler = makeHandler(backend)
        let subscriptionID = "term_123"

        let opened = await handler.handle(command(
            id: "cmd_terminal_open",
            command: .sessionTerminalOpen(.init(
                session: " pass-app ",
                subscriptionID: subscriptionID,
                previousRevision: nil
            ))
        ))

        XCTAssertEqual(opened.map(\.type), [RemoteEventType.acknowledgement, RemoteEventType.sessionTerminalSnapshot])
        guard case .sessionTerminalSnapshot(let snapshot) = opened[1].event else {
            return XCTFail("Expected terminal snapshot")
        }
        XCTAssertEqual(snapshot.subscriptionID, subscriptionID)
        XCTAssertEqual(snapshot.content, "\u{001B}[32mready\u{001B}[0m")
        XCTAssertEqual(snapshot.cursorX, 5)

        let input = await handler.handle(command(
            id: "cmd_terminal_input",
            command: .sessionTerminalInput(.init(
                session: "pass-app",
                subscriptionID: subscriptionID,
                input: "한글\r"
            ))
        ))
        XCTAssertEqual(input.map(\.type), [RemoteEventType.acknowledgement])
        XCTAssertEqual(backend.terminalInputs.first?.input, "한글\r")

        let closed = await handler.handle(command(
            id: "cmd_terminal_close",
            command: .sessionTerminalClose(.init(
                session: "pass-app",
                subscriptionID: subscriptionID
            ))
        ))
        XCTAssertEqual(closed.map(\.type), [RemoteEventType.acknowledgement])
        XCTAssertEqual(backend.closedTerminals.first?.subscriptionID, subscriptionID)
    }

    func testTerminalCommandsRejectInvalidSubscriptionAndOversizedInput() async {
        let backend = FakeRemoteCommandBackend()
        backend.sessions = [Self.session]
        let handler = makeHandler(backend)

        let invalidID = await handler.handle(command(
            id: "cmd_bad_terminal",
            command: .sessionTerminalOpen(.init(
                session: "pass-app",
                subscriptionID: "not valid",
                previousRevision: nil
            ))
        ))
        XCTAssertEqual(errorCode(invalidID), "invalid_subscription")

        let oversized = await handler.handle(command(
            id: "cmd_large_terminal_input",
            command: .sessionTerminalInput(.init(
                session: "pass-app",
                subscriptionID: "term_123",
                input: String(repeating: "🙂", count: RemoteWireLimits.terminalInputBytes / 4 + 1)
            ))
        ))
        XCTAssertEqual(errorCode(oversized), "terminal_input_too_large")
    }

    func testRejectsStaleAndFutureProtocolVersionsAndEmptyID() async {
        let backend = FakeRemoteCommandBackend()
        let handler = makeHandler(backend)

        for version in [0, RemoteProtocolVersion.current + 1] {
            let events = await handler.handle(RemoteCommandEnvelope(
                version: version,
                id: "cmd_version",
                sentAt: fixedDate,
                command: .sessionList
            ))
            XCTAssertEqual(errorCode(events), "unsupported_protocol_version")
        }

        let noID = await handler.handle(command(id: "  ", command: .projectList))
        XCTAssertEqual(errorCode(noID), "invalid_command")

        let oversizedID = await handler.handle(command(
            id: String(repeating: "x", count: RemoteCommandHandler.maximumIdentifierCharacters + 1),
            command: .projectList
        ))
        XCTAssertEqual(errorCode(oversizedID), "invalid_command")
        XCTAssertNil(oversizedID.first?.replyTo)
    }

    func testUnknownCommandReturnsCorrelatedError() async {
        let handler = makeHandler(FakeRemoteCommandBackend())
        let events = await handler.handle(command(
            id: "cmd_future",
            command: .unsupported(type: "session.teleport", payload: .object([:]))
        ))

        XCTAssertEqual(errorCode(events), "unsupported_command")
        XCTAssertEqual(events.first?.replyTo, "cmd_future")
    }

    private func makeHandler(_ backend: FakeRemoteCommandBackend) -> RemoteCommandHandler {
        var nextID = 0
        return RemoteCommandHandler(
            backend: backend,
            now: { self.fixedDate },
            makeID: {
                nextID += 1
                return "evt_\(nextID)"
            }
        )
    }

    private func command(id: String, command: RemoteCommand) -> RemoteCommandEnvelope {
        RemoteCommandEnvelope(id: id, sentAt: fixedDate, command: command)
    }

    private func errorCode(_ events: [RemoteEventEnvelope]) -> String? {
        guard case .error(let failure) = events.first?.event else { return nil }
        return failure.code
    }

    private static let session = RemoteSessionDTO(
        name: "pass-app",
        displayName: "App · main",
        defaultDisplayName: "app · main",
        agent: .claude,
        projectRoot: "/projects/app",
        cwd: "/projects/app",
        gitBranch: "main",
        attention: .init(status: .decision),
        lastMessage: nil,
        lastActivity: Date(timeIntervalSince1970: 1_752_580_800),
        isAttached: false,
        unacknowledged: true,
        launching: false
    )
}

@MainActor
private final class FakeRemoteCommandBackend: RemoteCommandBackend {
    var sessions: [RemoteSessionDTO] = []
    var projects: [RemoteProjectDTO] = []
    var createdCommands: [RemoteSessionCreateCommand] = []
    var sentCommands: [RemoteSessionSendMessageCommand] = []
    var decisionCommands: [RemoteSessionAnswerDecisionCommand] = []
    var terminalInputs: [RemoteSessionTerminalInputCommand] = []
    var closedTerminals: [RemoteSessionTerminalCloseCommand] = []
    var createError: RemoteExecutionError?
    var sendError: RemoteExecutionError?
    var decisionError: RemoteExecutionError?

    func currentSessions() -> [RemoteSessionDTO] { sessions }
    func currentProjects() -> [RemoteProjectDTO] { projects }

    func createSession(_ command: RemoteSessionCreateCommand) async throws -> String {
        guard projects.contains(where: { $0.rootPath == command.projectRoot }) else {
            throw RemoteExecutionError(
                code: "project_not_registered",
                message: "The requested project is not registered on this desktop."
            )
        }
        if let createError { throw createError }
        createdCommands.append(command)
        return "pass-created"
    }

    func sendMessage(_ command: RemoteSessionSendMessageCommand) async throws {
        if let sendError { throw sendError }
        guard sessions.contains(where: { $0.name == command.session }) else {
            throw RemoteExecutionError(code: "session_not_found", message: "The requested session is not running.")
        }
        sentCommands.append(command)
    }

    func answerDecision(_ command: RemoteSessionAnswerDecisionCommand) async throws {
        if let decisionError { throw decisionError }
        guard sessions.contains(where: { $0.name == command.session }) else {
            throw RemoteExecutionError(code: "session_not_found", message: "The requested session is not running.")
        }
        decisionCommands.append(command)
    }

    func openTerminal(_ command: RemoteSessionTerminalOpenCommand) async throws -> RemoteSessionTerminalSnapshot {
        guard sessions.contains(where: { $0.name == command.session }) else {
            throw RemoteExecutionError(code: "session_not_found", message: "The requested session is not running.")
        }
        return RemoteSessionTerminalSnapshot(
            session: command.session,
            subscriptionID: command.subscriptionID,
            revision: "rev_1",
            pane: TerminalPaneSnapshot(
                content: "\u{001B}[32mready\u{001B}[0m",
                columns: 80,
                rows: 24,
                cursorX: 5,
                cursorY: 2
            ),
            omitContent: command.previousRevision == "rev_1"
        )
    }

    func sendTerminalInput(_ command: RemoteSessionTerminalInputCommand) async throws {
        terminalInputs.append(command)
    }

    func closeTerminal(_ command: RemoteSessionTerminalCloseCommand) async throws {
        closedTerminals.append(command)
    }
}
