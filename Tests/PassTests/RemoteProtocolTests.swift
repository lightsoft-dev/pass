import XCTest
@testable import Pass

final class RemoteProtocolTests: XCTestCase {
    func testWirePrefixPreservesContentWhenOneGraphemeExceedsBudget() {
        let value = "a" + String(repeating: "\u{0301}", count: 300)

        let prefix = RemoteWireLimits.prefix(value, maximumUTF8Bytes: 500)

        XCTAssertFalse(prefix.isEmpty)
        XCTAssertEqual(prefix.unicodeScalars.first, "a".unicodeScalars.first)
        XCTAssertLessThanOrEqual(prefix.utf8.count, 500)
    }

    func testWireSuffixPreservesContentWhenOneGraphemeExceedsBudget() {
        let value = "a" + String(repeating: "\u{0301}", count: 300)

        let suffix = RemoteWireLimits.suffix(value, maximumUTF8Bytes: 500)

        XCTAssertFalse(suffix.isEmpty)
        XCTAssertLessThanOrEqual(suffix.utf8.count, 500)
        XCTAssertEqual(suffix.unicodeScalars.last, value.unicodeScalars.last)
    }

    private let timestamp = Date(timeIntervalSince1970: 1_752_580_800)

    func testSendMessageCommandDecodesFromVersionedWireShape() throws {
        let json = #"""
        {
          "version": 1,
          "id": "cmd_01JZ",
          "type": "session.sendMessage",
          "sentAt": "2025-07-15T12:00:00.123Z",
          "payload": {
            "session": "pass-my-app",
            "text": "Run the failing tests."
          }
        }
        """#

        let envelope = try RemoteWireCodec.decodeCommand(from: Data(json.utf8))

        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.id, "cmd_01JZ")
        XCTAssertEqual(envelope.type, RemoteCommandType.sessionSendMessage)
        XCTAssertEqual(
            envelope.command,
            .sessionSendMessage(.init(session: "pass-my-app", text: "Run the failing tests."))
        )
    }

    func testDecisionCommandRoundTrips() throws {
        let original = RemoteCommandEnvelope(
            id: "cmd_decision",
            sentAt: timestamp,
            command: .sessionAnswerDecision(.init(session: "pass-app", decision: .allowOnce))
        )

        let decoded = try RemoteWireCodec.decodeCommand(from: RemoteWireCodec.encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.type, RemoteCommandType.sessionAnswerDecision)
    }

    func testGrokSessionCreateCommandRoundTrips() throws {
        let original = RemoteCommandEnvelope(
            id: "cmd_grok",
            sentAt: timestamp,
            command: .sessionCreate(.init(
                projectRoot: "/projects/app",
                agent: .grok,
                initialPrompt: "Fix the failing test."
            ))
        )

        let decoded = try RemoteWireCodec.decodeCommand(from: RemoteWireCodec.encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.type, RemoteCommandType.sessionCreate)
    }

    func testUnknownCommandKeepsPayloadForForwardCompatibleError() throws {
        let json = #"""
        {
          "version": 1,
          "id": "cmd_new",
          "type": "future.command",
          "sentAt": "2025-07-15T12:00:00Z",
          "payload": { "flag": true }
        }
        """#

        let envelope = try RemoteWireCodec.decodeCommand(from: Data(json.utf8))

        XCTAssertEqual(
            envelope.command,
            .unsupported(type: "future.command", payload: .object(["flag": .bool(true)]))
        )
    }

    func testSnapshotEventRoundTripsAllSelectedMetadata() throws {
        let session = RemoteSessionDTO(
            name: "pass-app",
            displayName: "App · main",
            defaultDisplayName: "app · main",
            agent: .claude,
            projectRoot: "/projects/app",
            cwd: "/projects/app",
            gitBranch: "main",
            attention: .init(status: .decision, receivedAt: timestamp, preview: "Allow write?"),
            lastMessage: "Ready.",
            lastActivity: timestamp,
            isAttached: false,
            unacknowledged: true,
            launching: false
        )
        let snapshot = RemoteSessionSnapshot(
            generatedAt: timestamp,
            sessions: [session],
            projects: [.init(rootPath: "/projects/app", name: "app", emoji: "🚀")],
            capabilities: [.sessionsRead, .sessionsWrite, .projectsRead, .decisionsAnswer]
        )
        let original = RemoteEventEnvelope(
            id: "evt_snapshot",
            sentAt: timestamp,
            replyTo: "cmd_list",
            event: .sessionSnapshot(snapshot)
        )

        let decoded = try RemoteWireCodec.decodeEvent(from: RemoteWireCodec.encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.type, RemoteEventType.sessionSnapshot)
    }

    func testOversizedSnapshotIsBoundedAndReportsOriginalCounts() throws {
        let sessions = (0..<180).map { index in
            RemoteSessionDTO(
                name: "pass-app-\(index)",
                displayName: "App \(index)",
                defaultDisplayName: "app \(index)",
                agent: .claude,
                projectRoot: "/projects/app-\(index)",
                cwd: "/projects/app-\(index)",
                gitBranch: "main",
                attention: .init(status: .idle),
                lastMessage: String(repeating: "한", count: 10_000),
                lastActivity: timestamp,
                isAttached: false,
                unacknowledged: false,
                launching: false
            )
        }
        let projects = (0..<180).map {
            RemoteProjectDTO(rootPath: "/projects/app-\($0)", name: "app-\($0)")
        }
        let event = RemoteEventEnvelope(
            id: "evt_large_snapshot",
            sentAt: timestamp,
            event: .sessionSnapshot(.init(
                generatedAt: timestamp,
                sessions: sessions,
                projects: projects,
                capabilities: [.sessionsRead]
            ))
        )

        let data = try RemoteWireCodec.encodeForTransport(event)
        let decoded = try RemoteWireCodec.decodeEvent(from: data)

        XCTAssertLessThanOrEqual(data.count, RemoteWireLimits.maximumOutboundFrameBytes)
        guard case .sessionSnapshot(let snapshot) = decoded.event else {
            return XCTFail("Expected snapshot")
        }
        XCTAssertEqual(snapshot.truncated, true)
        XCTAssertEqual(snapshot.totalSessionCount, 180)
        XCTAssertEqual(snapshot.totalProjectCount, 180)
        XCTAssertLessThan(snapshot.sessions.count + snapshot.projects.count, 360)
        XCTAssertLessThanOrEqual(
            snapshot.sessions.first?.lastMessage?.utf8.count ?? 0,
            RemoteWireLimits.lastMessageBytes
        )
    }

    func testSnapshotItemCountsAreCappedEvenBelowByteBudget() throws {
        let projects = (0...RemoteWireLimits.maximumSnapshotItems).map {
            RemoteProjectDTO(rootPath: "/p/\($0)", name: "p\($0)")
        }
        let event = RemoteEventEnvelope(
            id: "evt_many_projects",
            sentAt: timestamp,
            event: .sessionSnapshot(.init(
                generatedAt: timestamp,
                sessions: [],
                projects: projects,
                capabilities: [.projectsRead]
            ))
        )

        let decoded = try RemoteWireCodec.decodeEvent(
            from: RemoteWireCodec.encodeForTransport(event)
        )

        guard case .sessionSnapshot(let snapshot) = decoded.event else {
            return XCTFail("Expected snapshot")
        }
        XCTAssertEqual(snapshot.projects.count, RemoteWireLimits.maximumSnapshotItems)
        XCTAssertEqual(snapshot.truncated, true)
        XCTAssertEqual(snapshot.totalProjectCount, RemoteWireLimits.maximumSnapshotItems + 1)
        XCTAssertEqual(snapshot.totalSessionCount, 0)
    }

    func testSessionMessageStreamEventRoundTripsWithSelfContainedText() throws {
        let original = RemoteEventEnvelope(
            id: "evt_stream",
            sentAt: timestamp,
            event: .sessionMessageUpdated(.init(
                session: "pass-app",
                messageID: "msg_turn",
                sequence: 4,
                text: "Building the mobile bundle…",
                truncated: false
            ))
        )

        let decoded = try RemoteWireCodec.decodeEvent(from: RemoteWireCodec.encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.type, RemoteEventType.sessionMessageUpdated)
    }

    func testSessionMessageStreamTextIsBoundedByUTF8Bytes() throws {
        let payload = RemoteSessionMessageStream(
            session: "pass-app",
            messageID: "msg_large",
            sequence: 1,
            text: String(repeating: "🙂", count: RemoteWireLimits.streamMessageBytes),
            truncated: false
        )

        XCTAssertLessThanOrEqual(payload.text.utf8.count, RemoteWireLimits.streamMessageBytes)
        XCTAssertTrue(payload.truncated)
    }

    func testProjectAgentCommandsAndSnapshotRoundTrip() throws {
        let commands: [RemoteCommand] = [
            .projectAgentGet(.init(projectRoot: "/projects/app")),
            .projectAgentSend(.init(projectRoot: "/projects/app", text: "Run tests")),
        ]
        for command in commands {
            let envelope = RemoteCommandEnvelope(id: "cmd_pa", sentAt: timestamp, command: command)
            XCTAssertEqual(try RemoteWireCodec.decodeCommand(from: RemoteWireCodec.encode(envelope)), envelope)
        }

        let snapshot = RemoteProjectAgentSnapshot(
            projectRoot: "/projects/app",
            messages: [.init(id: "message_1", role: .assistant, text: "Ready")],
            isReady: true,
            isResponding: false,
            status: "Idle",
            modelLabel: "provider/model",
            truncated: true
        )
        let event = RemoteEventEnvelope(
            id: "evt_pa", sentAt: timestamp, replyTo: "cmd_pa",
            event: .projectAgentSnapshot(snapshot)
        )
        XCTAssertEqual(try RemoteWireCodec.decodeEvent(from: RemoteWireCodec.encode(event)), event)
        XCTAssertLessThan(try RemoteWireCodec.encodeForTransport(event).count,
                          RemoteWireLimits.maximumOutboundFrameBytes)
    }

    func testProjectAgentNoticeMapsToWireRole() throws {
        let notice = RemoteProjectAgentMessage(
            ProjectAgentMessage(role: .notice, text: "Worker needs your attention")
        )

        XCTAssertEqual(notice.role, .notice)
        XCTAssertEqual(notice.text, "Worker needs your attention")
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteProjectAgentMessage.self, from: JSONEncoder().encode(notice)),
            notice
        )
    }

    func testProjectAgentSnapshotCapsMessagesAndUTF8Fields() throws {
        let messages = (0...RemoteWireLimits.maximumProjectAgentMessages).map { index in
            RemoteProjectAgentMessage(
                id: "message_\(index)", role: .assistant,
                text: String(repeating: "🙂", count: RemoteWireLimits.projectAgentMessageBytes)
            )
        }
        let snapshot = RemoteProjectAgentSnapshot(
            projectRoot: "/projects/app", messages: messages,
            isReady: true, isResponding: true,
            status: String(repeating: "🙂", count: 1_000),
            modelLabel: String(repeating: "🙂", count: 1_000)
        )
        XCTAssertEqual(snapshot.messages.count, RemoteWireLimits.maximumProjectAgentMessages)
        XCTAssertEqual(snapshot.messages.first?.id, "message_1")
        XCTAssertTrue(snapshot.truncated)
        XCTAssertTrue(snapshot.messages.allSatisfy {
            $0.text.utf8.count <= RemoteWireLimits.projectAgentMessageBytes
        })
        XCTAssertTrue(snapshot.messages.allSatisfy(\.truncated))
        XCTAssertLessThanOrEqual(snapshot.status.utf8.count, RemoteWireLimits.projectAgentStatusBytes)
        XCTAssertLessThanOrEqual(snapshot.modelLabel.utf8.count, RemoteWireLimits.projectAgentModelBytes)
        let event = RemoteEventEnvelope(id: "evt_pa_bound", sentAt: timestamp,
                                        event: .projectAgentSnapshot(snapshot))
        XCTAssertLessThan(try RemoteWireCodec.encodeForTransport(event).count,
                          RemoteWireLimits.maximumOutboundFrameBytes)
    }

    func testProjectAgentTransportDropsOldestEscapedMessagesAndTrimsLastIfNeeded() throws {
        let escaped = String(repeating: "\u{0000}", count: RemoteWireLimits.projectAgentMessageBytes)
        let snapshot = RemoteProjectAgentSnapshot(
            projectRoot: "/projects/app",
            messages: (0..<RemoteWireLimits.maximumProjectAgentMessages).map {
                RemoteProjectAgentMessage(id: "message_\($0)", role: .assistant, text: escaped)
            },
            isReady: true, isResponding: false, status: "Ready", modelLabel: "provider/model"
        )
        let event = RemoteEventEnvelope(id: "evt_pa_escaped", sentAt: timestamp,
                                        event: .projectAgentSnapshot(snapshot))
        let bounded = try RemoteWireCodec.encodeForTransport(event)
        XCTAssertLessThanOrEqual(bounded.count, RemoteWireLimits.maximumOutboundFrameBytes)
        guard case .projectAgentSnapshot(let retained) = try RemoteWireCodec.decodeEvent(from: bounded).event else {
            return XCTFail("Expected Pa snapshot")
        }
        XCTAssertLessThan(retained.messages.count, RemoteWireLimits.maximumProjectAgentMessages)
        XCTAssertEqual(retained.messages.last?.id, "message_63")
        XCTAssertTrue(retained.truncated)

        let tiny = try RemoteWireCodec.encodeForTransport(event, maximumBytes: 500)
        XCTAssertLessThanOrEqual(tiny.count, 500)
        guard case .projectAgentSnapshot(let shortened) = try RemoteWireCodec.decodeEvent(from: tiny).event else {
            return XCTFail("Expected shortened Pa snapshot")
        }
        XCTAssertEqual(shortened.messages.count, 1)
        XCTAssertTrue(shortened.truncated)
        XCTAssertTrue(shortened.messages[0].truncated)
        XCTAssertLessThan(shortened.messages[0].text.utf8.count, escaped.utf8.count)
    }

    func testProjectAgentAssistantClippingPreservesConclusion() throws {
        let conclusion = "CONCLUSION: finished ✅"
        let oversized = String(repeating: "🙂", count: RemoteWireLimits.projectAgentMessageBytes / 4)
            + conclusion
        let assistant = RemoteProjectAgentMessage(id: "assistant", role: .assistant, text: oversized)
        let user = RemoteProjectAgentMessage(id: "user", role: .user, text: oversized)

        XCTAssertTrue(assistant.truncated)
        XCTAssertLessThanOrEqual(assistant.text.utf8.count, RemoteWireLimits.projectAgentMessageBytes)
        XCTAssertTrue(assistant.text.hasSuffix(conclusion))
        XCTAssertTrue(user.truncated)
        XCTAssertTrue(user.text.hasPrefix("🙂"))
        XCTAssertFalse(user.text.hasSuffix(conclusion))

        let escaped = String(repeating: "\"", count: RemoteWireLimits.projectAgentMessageBytes - conclusion.utf8.count)
            + conclusion
        let event = RemoteEventEnvelope(
            id: "evt_pa_conclusion", sentAt: timestamp,
            event: .projectAgentSnapshot(.init(
                projectRoot: "/projects/app",
                messages: [.init(id: "assistant", role: .assistant, text: escaped)],
                isReady: true, isResponding: false, status: "Ready", modelLabel: "model"
            ))
        )
        let bounded = try RemoteWireCodec.encodeForTransport(event, maximumBytes: 700)
        guard case .projectAgentSnapshot(let snapshot) = try RemoteWireCodec.decodeEvent(from: bounded).event else {
            return XCTFail("Expected Pa snapshot")
        }
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertTrue(snapshot.messages[0].truncated)
        XCTAssertTrue(snapshot.messages[0].text.hasSuffix(conclusion))
    }

    func testTerminalCommandAndSnapshotUseMobileWireKeys() throws {
        let command = RemoteCommandEnvelope(
            id: "cmd_terminal",
            sentAt: timestamp,
            command: .sessionTerminalOpen(.init(
                session: "pass-app",
                subscriptionID: "term_123",
                previousRevision: "rev_1"
            ))
        )

        let encodedCommand = try RemoteWireCodec.encode(command)
        let decodedCommand = try RemoteWireCodec.decodeCommand(from: encodedCommand)

        XCTAssertEqual(decodedCommand, command)
        XCTAssertTrue(String(decoding: encodedCommand, as: UTF8.self).contains(#""subscriptionId":"term_123""#))

        let snapshot = RemoteSessionTerminalSnapshot(
            session: "pass-app",
            subscriptionID: "term_123",
            revision: "rev_2",
            pane: .init(
                content: "\u{001B}[32mready\u{001B}[0m",
                columns: 120,
                rows: 36,
                cursorX: 5,
                cursorY: 2
            )
        )
        let event = RemoteEventEnvelope(
            id: "evt_terminal",
            sentAt: timestamp,
            event: .sessionTerminalSnapshot(snapshot)
        )

        let decodedEvent = try RemoteWireCodec.decodeEvent(from: RemoteWireCodec.encode(event))

        XCTAssertEqual(decodedEvent, event)
        XCTAssertEqual(decodedEvent.type, RemoteEventType.sessionTerminalSnapshot)
    }
}
