import Foundation
import XCTest
@testable import Pass

@MainActor
final class RemoteGatewayTests: XCTestCase {
    func testEnvironmentOverridesStableUserDefaultsConfiguration() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: RemoteGatewayPreferenceKey.enabled)
        defaults.set("wss://stored.example/connect", forKey: RemoteGatewayPreferenceKey.relayURL)
        defaults.set("desk_stored", forKey: RemoteGatewayPreferenceKey.desktopID)
        defaults.set("stored-token", forKey: RemoteGatewayPreferenceKey.authorizationToken)

        let configuration = RemoteGatewayConfiguration.load(
            environment: [
                RemoteGatewayEnvironmentKey.enabled: "0",
                RemoteGatewayEnvironmentKey.relayURL: "ws://127.0.0.1:9001/connect",
                RemoteGatewayEnvironmentKey.desktopID: "desk_env",
                RemoteGatewayEnvironmentKey.authorizationToken: "env-token",
            ],
            defaults: defaults
        )

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.relayURL?.absoluteString, "ws://127.0.0.1:9001/connect")
        XCTAssertEqual(configuration.desktopID, "desk_env")
        XCTAssertEqual(configuration.authorizationToken, "env-token")
    }

    func testGeneratedDesktopIDIsStableInDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = RemoteGatewayConfiguration.load(environment: [:], defaults: defaults)
        let second = RemoteGatewayConfiguration.load(environment: [:], defaults: defaults)

        XCTAssertTrue(first.desktopID.hasPrefix("desk_"))
        XCTAssertEqual(second.desktopID, first.desktopID)
    }

    func testTransportSecurityValidation() throws {
        let local = RemoteGatewayConfiguration(
            isEnabled: true,
            relayURL: URL(string: "ws://localhost:9001/connect")!,
            desktopID: "desk_local"
        )
        XCTAssertNoThrow(try local.validatedRelayURL())

        let insecureRemote = RemoteGatewayConfiguration(
            isEnabled: true,
            relayURL: URL(string: "ws://relay.example/connect")!,
            desktopID: "desk_remote",
            authorizationToken: "token"
        )
        XCTAssertThrowsError(try insecureRemote.validatedRelayURL()) { error in
            XCTAssertEqual(error as? RemoteGatewayConfigurationError, .insecureNonLoopbackURL)
        }

        let unauthenticatedRemote = RemoteGatewayConfiguration(
            isEnabled: true,
            relayURL: URL(string: "wss://relay.example/connect")!,
            desktopID: "desk_remote"
        )
        XCTAssertThrowsError(try unauthenticatedRemote.validatedRelayURL()) { error in
            XCTAssertEqual(error as? RemoteGatewayConfigurationError, .missingAuthorizationToken)
        }

        let request = try RemoteGatewayConfiguration(
            isEnabled: true,
            relayURL: URL(string: "wss://relay.example/connect")!,
            desktopID: "desk_remote",
            authorizationToken: "secret"
        ).urlRequest()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pass-Desktop-ID"), "desk_remote")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pass-Role"), "desktop")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "pass.control.v1")
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "desktopId" })?.value, "desk_remote")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "role" })?.value, "desktop")
    }

    func testConfigurationNormalizesRelayBaseAndRejectsInvalidIdentity() throws {
        let base = RemoteGatewayConfiguration(
            isEnabled: true,
            relayURL: URL(string: "wss://relay.example")!,
            desktopID: "desk_valid",
            authorizationToken: "secret"
        )
        XCTAssertEqual(try base.validatedRelayURL().absoluteString, "wss://relay.example/connect")

        let invalidID = RemoteGatewayConfiguration(
            isEnabled: true,
            relayURL: URL(string: "wss://relay.example/connect")!,
            desktopID: "desk invalid",
            authorizationToken: "secret"
        )
        XCTAssertThrowsError(try invalidID.validatedRelayURL()) { error in
            XCTAssertEqual(error as? RemoteGatewayConfigurationError, .invalidDesktopID)
        }

        let embeddedCredentials = RemoteGatewayConfiguration(
            isEnabled: true,
            relayURL: URL(string: "wss://user:password@relay.example/connect")!,
            desktopID: "desk_valid",
            authorizationToken: "secret"
        )
        XCTAssertThrowsError(try embeddedCredentials.validatedRelayURL()) { error in
            XCTAssertEqual(error as? RemoteGatewayConfigurationError, .invalidRelayURL)
        }
    }

    func testDeveloperPairingPayloadUsesMobileWireKeys() throws {
        let payload = DeveloperPairingPayload(
            relayURL: "https://relay.example/connect",
            desktopID: "desk_valid",
            authorizationToken: "secret"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertEqual(object["v"] as? Int, RemoteProtocolVersion.current)
        XCTAssertEqual(object["relayUrl"] as? String, "https://relay.example/connect")
        XCTAssertEqual(object["desktopId"] as? String, "desk_valid")
        XCTAssertEqual(object["authorizationToken"] as? String, "secret")
        XCTAssertNil(object["relayURL"])
        XCTAssertNil(object["desktopID"])
    }

    func testDisabledGatewayNeverCreatesTransport() async {
        let handler = GatewayStubHandler()
        let transport = ScriptedRemoteTransport(incoming: [])
        let gateway = RemoteGateway(
            configuration: .disabled,
            handler: handler,
            transportFactory: { transport }
        )

        await gateway.start()

        let state = await gateway.state
        let connections = await transport.connectCount
        XCTAssertEqual(state, .disabled)
        XCTAssertEqual(connections, 0)
    }

    func testGatewayPublishesInitialSnapshotHandlesCommandAndBoundsFrames() async throws {
        let command = RemoteCommandEnvelope(
            id: "cmd_list",
            sentAt: Date(timeIntervalSince1970: 1_752_580_800),
            command: .sessionList
        )
        let oversized = RemoteTransportMessage.data(Data(
            repeating: 0x20,
            count: RemoteGateway.maximumInboundFrameBytes + 1
        ))
        let transport = ScriptedRemoteTransport(incoming: [
            .data(try RemoteWireCodec.encode(command)),
            oversized,
        ])
        let gateway = RemoteGateway(
            configuration: .init(
                isEnabled: true,
                relayURL: URL(string: "ws://127.0.0.1:9001/connect")!,
                desktopID: "desk_test",
                minimumReconnectDelay: 10,
                maximumReconnectDelay: 10
            ),
            handler: GatewayStubHandler(),
            transportFactory: { transport }
        )

        await gateway.start()
        for _ in 0..<100 {
            if await transport.sentCount >= 3 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let messages = await transport.sentMessages
        await gateway.stop()

        let events = try messages.map { try RemoteWireCodec.decodeEvent(from: $0.data) }
        XCTAssertEqual(events.map(\.type), [
            RemoteEventType.sessionSnapshot,
            RemoteEventType.acknowledgement,
            RemoteEventType.error,
        ])
        guard case .error(let failure) = events.last?.event else {
            return XCTFail("Expected oversized-frame error")
        }
        XCTAssertEqual(failure.code, "frame_too_large")
    }

    func testGatewayPublishesOrderedSelfContainedMessageStreamEvents() async throws {
        let transport = ScriptedRemoteTransport(incoming: [])
        let gateway = RemoteGateway(
            configuration: .init(
                isEnabled: true,
                relayURL: URL(string: "ws://127.0.0.1:9001/connect")!,
                desktopID: "desk_stream",
                minimumReconnectDelay: 10,
                maximumReconnectDelay: 10
            ),
            handler: GatewayStubHandler(),
            transportFactory: { transport }
        )

        await gateway.start()
        for _ in 0..<100 {
            if await transport.sentCount >= 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        var session = Session(
            name: "pass-app",
            projectRoot: "/projects/app",
            cwd: "/projects/app",
            agent: .claude,
            lastActivity: Date(),
            isAttached: false
        )
        session.lastMessage = "Previous response"
        session.liveTail = "Running"
        await gateway.publishMessageStreams([RemoteMessageStreamSource(session)])

        session.liveTail = "Running tests"
        await gateway.publishMessageStreams([RemoteMessageStreamSource(session)])

        session.liveTail = nil
        session.lastMessage = "Running tests completed"
        await gateway.publishMessageStreams([RemoteMessageStreamSource(session)])

        let messages = await transport.sentMessages
        await gateway.stop()
        let events = try messages.map { try RemoteWireCodec.decodeEvent(from: $0.data) }
        XCTAssertEqual(Array(events.suffix(3).map(\.type)), [
            RemoteEventType.sessionMessageStarted,
            RemoteEventType.sessionMessageUpdated,
            RemoteEventType.sessionMessageCompleted,
        ])

        let payloads = events.suffix(3).compactMap { event -> RemoteSessionMessageStream? in
            switch event.event {
            case .sessionMessageStarted(let payload),
                 .sessionMessageUpdated(let payload),
                 .sessionMessageCompleted(let payload):
                return payload
            default:
                return nil
            }
        }
        XCTAssertEqual(payloads.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(payloads.map(\.text), [
            "Running",
            "Running tests",
            "Running tests completed",
        ])
        XCTAssertEqual(Set(payloads.map(\.messageID)).count, 1)
    }

    func testGatewayDoesNotStartStreamFromPreviousCompletedResponse() async throws {
        let transport = ScriptedRemoteTransport(incoming: [])
        let gateway = RemoteGateway(
            configuration: .init(
                isEnabled: true,
                relayURL: URL(string: "ws://127.0.0.1:9001/connect")!,
                desktopID: "desk_stream_baseline",
                minimumReconnectDelay: 10,
                maximumReconnectDelay: 10
            ),
            handler: GatewayStubHandler(),
            transportFactory: { transport }
        )

        await gateway.start()
        for _ in 0..<100 {
            if await transport.sentCount >= 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        var session = Session(
            name: "pass-app",
            projectRoot: "/projects/app",
            cwd: "/projects/app",
            agent: .claude,
            lastActivity: Date(),
            isAttached: false
        )
        session.lastMessage = "Previous response"
        session.liveTail = "Previous response"
        await gateway.publishMessageStreams([RemoteMessageStreamSource(session)])

        let sentCount = await transport.sentCount
        XCTAssertEqual(sentCount, 1, "only the initial snapshot should be sent")
        await gateway.stop()
    }

    func testSnapshotHookCoalescesBurstAfterCurrentMainActorTurn() async throws {
        let publisher = CountingSnapshotPublisher()
        let hook = RemoteSnapshotPublicationHook(publisher: publisher, debounceNanoseconds: 1_000_000)

        hook.schedule()
        hook.schedule()
        hook.schedule()
        try await Task.sleep(nanoseconds: 25_000_000)

        let count = await publisher.count
        XCTAssertEqual(count, 1)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "RemoteGatewayTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

@MainActor
private final class GatewayStubHandler: RemoteCommandHandling {
    func handle(_ envelope: RemoteCommandEnvelope) async -> [RemoteEventEnvelope] {
        [RemoteEventEnvelope(
            id: "evt_ack",
            sentAt: envelope.sentAt,
            replyTo: envelope.id,
            event: .acknowledgement(.init(commandType: envelope.type, resourceID: nil))
        )]
    }

    func makeSnapshotEvent(replyTo: String?) -> RemoteEventEnvelope {
        RemoteEventEnvelope(
            id: "evt_snapshot",
            sentAt: Date(timeIntervalSince1970: 1_752_580_800),
            replyTo: replyTo,
            event: .sessionSnapshot(.init(
                generatedAt: Date(timeIntervalSince1970: 1_752_580_800),
                sessions: [],
                projects: [],
                capabilities: [.sessionsRead]
            ))
        )
    }
}

private actor ScriptedRemoteTransport: RemoteGatewayTransport {
    private var incoming: [RemoteTransportMessage]
    private var waiting: CheckedContinuation<RemoteTransportMessage, Error>?
    private(set) var connectCount = 0
    private(set) var sentMessages: [RemoteTransportMessage] = []

    init(incoming: [RemoteTransportMessage]) {
        self.incoming = incoming
    }

    var sentCount: Int { sentMessages.count }

    func connect() async throws {
        connectCount += 1
    }

    func receive() async throws -> RemoteTransportMessage {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
        }
    }

    func send(_ message: RemoteTransportMessage) async throws {
        sentMessages.append(message)
    }

    func disconnect() async {
        let continuation = waiting
        waiting = nil
        continuation?.resume(throwing: CancellationError())
    }
}

private actor CountingSnapshotPublisher: RemoteSnapshotPublishing {
    private(set) var count = 0

    func publishSnapshot() async {
        count += 1
    }
}
