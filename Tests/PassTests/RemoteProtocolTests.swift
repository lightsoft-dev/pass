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
}
