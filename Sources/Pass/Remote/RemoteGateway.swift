import Foundation

enum RemoteGatewayPreferenceKey {
    static let enabled = "remoteAccess.enabled"
    static let relayURL = "remoteAccess.relayURL"
    static let desktopID = "remoteAccess.desktopID"
    /// Phase 1 storage only. Pairing should move device credentials to Keychain in phase 2.
    static let authorizationToken = "remoteAccess.authorizationToken"
}

enum RemoteGatewayEnvironmentKey {
    static let enabled = "PASS_REMOTE_ENABLED"
    static let relayURL = "PASS_REMOTE_URL"
    static let desktopID = "PASS_REMOTE_DESKTOP_ID"
    static let authorizationToken = "PASS_REMOTE_TOKEN"
}

enum RemoteGatewayConfigurationError: Error, Equatable, LocalizedError {
    case missingRelayURL
    case missingDesktopID
    case invalidDesktopID
    case missingAuthorizationToken
    case invalidRelayURL
    case unsupportedScheme(String)
    case insecureNonLoopbackURL

    var errorDescription: String? {
        switch self {
        case .missingRelayURL:
            return "Remote access is enabled but no relay URL is configured."
        case .missingDesktopID:
            return "Remote access is enabled but no desktop id is configured."
        case .invalidDesktopID:
            return "Desktop id must use 1–128 letters, numbers, dots, underscores, colons, or hyphens."
        case .missingAuthorizationToken:
            return "A remote relay requires an authorization token."
        case .invalidRelayURL:
            return "Remote relay URL must include a host and cannot contain user credentials."
        case .unsupportedScheme(let scheme):
            return "Remote relay URL scheme '\(scheme)' is not supported."
        case .insecureNonLoopbackURL:
            return "Insecure WebSockets are allowed only for a loopback test server."
        }
    }
}

/// Feature configuration for the outbound-only desktop socket. Environment values take
/// precedence so integration tests can point a regular app build at a local WebSocket server.
struct RemoteGatewayConfiguration: Equatable, Sendable {
    var isEnabled: Bool
    var relayURL: URL?
    var desktopID: String
    var authorizationToken: String?
    var minimumReconnectDelay: TimeInterval
    var maximumReconnectDelay: TimeInterval
    var requestTimeout: TimeInterval

    init(
        isEnabled: Bool,
        relayURL: URL?,
        desktopID: String,
        authorizationToken: String? = nil,
        minimumReconnectDelay: TimeInterval = 1,
        maximumReconnectDelay: TimeInterval = 30,
        requestTimeout: TimeInterval = 15
    ) {
        self.isEnabled = isEnabled
        self.relayURL = relayURL
        self.desktopID = desktopID
        self.authorizationToken = authorizationToken
        self.minimumReconnectDelay = minimumReconnectDelay
        self.maximumReconnectDelay = maximumReconnectDelay
        self.requestTimeout = requestTimeout
    }

    static let disabled = RemoteGatewayConfiguration(
        isEnabled: false,
        relayURL: nil,
        desktopID: "disabled"
    )

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> RemoteGatewayConfiguration {
        let enabled = environment[RemoteGatewayEnvironmentKey.enabled].flatMap(parseBool)
            ?? defaults.bool(forKey: RemoteGatewayPreferenceKey.enabled)

        let rawURL = environment[RemoteGatewayEnvironmentKey.relayURL]
            ?? defaults.string(forKey: RemoteGatewayPreferenceKey.relayURL)
        let relayURL = rawURL.flatMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(string: trimmed)
        }

        let desktopID: String
        if let override = environment[RemoteGatewayEnvironmentKey.desktopID],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            desktopID = override.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let stored = defaults.string(forKey: RemoteGatewayPreferenceKey.desktopID),
                  !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            desktopID = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            desktopID = "desk_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
            defaults.set(desktopID, forKey: RemoteGatewayPreferenceKey.desktopID)
        }

        let authorizationToken: String?
        if let override = environment[RemoteGatewayEnvironmentKey.authorizationToken] {
            authorizationToken = override.isEmpty ? nil : override
        } else {
            authorizationToken = defaults.string(forKey: RemoteGatewayPreferenceKey.authorizationToken)
        }

        return RemoteGatewayConfiguration(
            isEnabled: enabled,
            relayURL: relayURL,
            desktopID: desktopID,
            authorizationToken: authorizationToken
        )
    }

    func validatedRelayURL() throws -> URL {
        guard let relayURL else { throw RemoteGatewayConfigurationError.missingRelayURL }
        let trimmedDesktopID = desktopID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDesktopID.isEmpty else {
            throw RemoteGatewayConfigurationError.missingDesktopID
        }
        guard trimmedDesktopID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw RemoteGatewayConfigurationError.invalidDesktopID
        }
        guard relayURL.host?.isEmpty == false, relayURL.user == nil, relayURL.password == nil else {
            throw RemoteGatewayConfigurationError.invalidRelayURL
        }

        let scheme = relayURL.scheme?.lowercased() ?? ""
        switch scheme {
        case "wss":
            let token = authorizationToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            if !Self.isLoopback(relayURL.host), token?.isEmpty ?? true {
                throw RemoteGatewayConfigurationError.missingAuthorizationToken
            }
            return Self.addConnectPathIfMissing(to: relayURL)
        case "ws":
            guard Self.isLoopback(relayURL.host) else {
                throw RemoteGatewayConfigurationError.insecureNonLoopbackURL
            }
            return Self.addConnectPathIfMissing(to: relayURL)
        default:
            throw RemoteGatewayConfigurationError.unsupportedScheme(scheme)
        }
    }

    func urlRequest() throws -> URLRequest {
        let relayURL = try validatedRelayURL()
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "desktopId" || $0.name == "role" }
        queryItems.append(URLQueryItem(name: "desktopId", value: desktopID))
        queryItems.append(URLQueryItem(name: "role", value: "desktop"))
        components?.queryItems = queryItems

        var request = URLRequest(url: components?.url ?? relayURL, timeoutInterval: max(1, requestTimeout))
        request.setValue(String(RemoteProtocolVersion.current), forHTTPHeaderField: "X-Pass-Protocol-Version")
        request.setValue(desktopID, forHTTPHeaderField: "X-Pass-Desktop-ID")
        request.setValue("desktop", forHTTPHeaderField: "X-Pass-Role")
        request.setValue("pass.control.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let token = authorizationToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func addConnectPathIfMissing(to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.isEmpty || components.path == "/" else {
            return url
        }
        components.path = "/connect"
        return components.url ?? url
    }
}

enum RemoteTransportMessage: Equatable, Sendable {
    case text(String)
    case data(Data)

    var data: Data {
        switch self {
        case .text(let text): return Data(text.utf8)
        case .data(let data): return data
        }
    }

    var byteCount: Int {
        switch self {
        case .text(let text): return text.utf8.count
        case .data(let data): return data.count
        }
    }
}

enum RemoteGatewayTransportError: Error {
    case notConnected
    case nonUTF8Payload
}

protocol RemoteGatewayTransport: Sendable {
    func connect() async throws
    func receive() async throws -> RemoteTransportMessage
    func send(_ message: RemoteTransportMessage) async throws
    func disconnect() async
}

/// Foundation transport used in production. It creates an outbound WebSocket task only; no
/// listener or change to the loopback hook server is involved.
actor URLSessionRemoteTransport: RemoteGatewayTransport {
    private let configuration: RemoteGatewayConfiguration
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(configuration: RemoteGatewayConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func connect() async throws {
        guard task == nil else { return }
        let task = session.webSocketTask(with: try configuration.urlRequest())
        self.task = task
        task.resume()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: ()) }
                }
            }
        } catch {
            self.task = nil
            task.cancel(with: .protocolError, reason: nil)
            throw error
        }
    }

    func receive() async throws -> RemoteTransportMessage {
        guard let task else { throw RemoteGatewayTransportError.notConnected }
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: throw RemoteGatewayTransportError.nonUTF8Payload
        }
    }

    func send(_ message: RemoteTransportMessage) async throws {
        guard let task else { throw RemoteGatewayTransportError.notConnected }
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    func disconnect() async {
        let active = task
        task = nil
        active?.cancel(with: .goingAway, reason: nil)
    }
}

enum RemoteGatewayState: Equatable, Sendable {
    case disabled
    case stopped
    case connecting
    case connected
    case waitingToReconnect(attempt: Int, lastError: String)
    case failedConfiguration(String)
}

typealias RemoteGatewayTransportFactory = @Sendable () -> any RemoteGatewayTransport
typealias RemoteGatewayStateObserver = @MainActor @Sendable (RemoteGatewayState) -> Void

actor RemoteGateway: RemoteSnapshotPublishing {
    static let maximumInboundFrameBytes = 1_048_576
    static let maximumOutboundFrameBytes = RemoteWireLimits.maximumOutboundFrameBytes

    private let configuration: RemoteGatewayConfiguration
    private let handler: any RemoteCommandHandling
    private let transportFactory: RemoteGatewayTransportFactory
    private let stateObserver: RemoteGatewayStateObserver?

    private var lifecycleTask: Task<Void, Never>?
    private var transport: (any RemoteGatewayTransport)?
    private var snapshotPending = true
    private(set) var state: RemoteGatewayState = .stopped

    init(
        configuration: RemoteGatewayConfiguration,
        handler: any RemoteCommandHandling,
        transportFactory: RemoteGatewayTransportFactory? = nil,
        stateObserver: RemoteGatewayStateObserver? = nil
    ) {
        self.configuration = configuration
        self.handler = handler
        self.transportFactory = transportFactory ?? {
            URLSessionRemoteTransport(configuration: configuration)
        }
        self.stateObserver = stateObserver
    }

    func start() {
        guard lifecycleTask == nil else { return }
        guard configuration.isEnabled else {
            updateState(.disabled)
            return
        }
        do {
            _ = try configuration.validatedRelayURL()
        } catch {
            updateState(.failedConfiguration(error.localizedDescription))
            return
        }

        updateState(.connecting)
        lifecycleTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    func stop() async {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        let active = transport
        transport = nil
        await active?.disconnect()
        updateState(.stopped)
    }

    /// Sends a full snapshot when connected, or remembers one dirty bit for the next reconnect.
    func publishSnapshot() async {
        snapshotPending = true
        guard state == .connected, let transport else { return }
        do {
            try await sendSnapshot(using: transport)
            snapshotPending = false
        } catch {
            await transport.disconnect()
        }
    }

    private func runConnectionLoop() async {
        var attempt = 0
        var delay = max(0.05, configuration.minimumReconnectDelay)
        let maximumDelay = max(delay, configuration.maximumReconnectDelay)

        while !Task.isCancelled {
            attempt += 1
            updateState(.connecting)
            let candidate = transportFactory()
            transport = candidate

            do {
                try await candidate.connect()
                try Task.checkCancellation()
                updateState(.connected)
                attempt = 0
                delay = max(0.05, configuration.minimumReconnectDelay)

                // Always introduce the desktop with a full snapshot. This also clears a dirty
                // snapshot accumulated while it was offline.
                try await sendSnapshot(using: candidate)
                snapshotPending = false

                while !Task.isCancelled {
                    let message = try await candidate.receive()
                    try await handleIncoming(message, using: candidate)
                }
            } catch {
                if !Task.isCancelled {
                    updateState(.waitingToReconnect(
                        attempt: max(1, attempt),
                        lastError: Self.publicErrorDescription(error)
                    ))
                }
            }

            await candidate.disconnect()
            transport = nil
            guard !Task.isCancelled else { break }

            let nanoseconds = UInt64(min(delay, maximumDelay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            delay = min(maximumDelay, delay * 2)
        }

        if state != .disabled {
            updateState(.stopped)
        }
    }

    private func handleIncoming(
        _ message: RemoteTransportMessage,
        using transport: any RemoteGatewayTransport
    ) async throws {
        guard message.byteCount <= Self.maximumInboundFrameBytes else {
            let failure = RemoteEventEnvelope(
                id: "evt_\(UUID().uuidString.lowercased())",
                sentAt: Date(),
                event: .error(RemoteCommandFailure(
                    code: "frame_too_large",
                    message: "Control frames are limited to 1 MiB.",
                    retryable: false
                ))
            )
            try await send(failure, using: transport)
            return
        }

        let command: RemoteCommandEnvelope
        do {
            command = try RemoteWireCodec.decodeCommand(from: message.data)
        } catch {
            let failure = RemoteEventEnvelope(
                id: "evt_\(UUID().uuidString.lowercased())",
                sentAt: Date(),
                event: .error(RemoteCommandFailure(
                    code: "malformed_command",
                    message: "Command envelope could not be decoded.",
                    retryable: false
                ))
            )
            try await send(failure, using: transport)
            return
        }

        for event in await handler.handle(command) {
            try await send(event, using: transport)
        }
    }

    private func sendSnapshot(using transport: any RemoteGatewayTransport) async throws {
        let event = await handler.makeSnapshotEvent(replyTo: nil)
        try await send(event, using: transport)
    }

    private func send(
        _ event: RemoteEventEnvelope,
        using transport: any RemoteGatewayTransport
    ) async throws {
        let data = try RemoteWireCodec.encodeForTransport(
            event,
            maximumBytes: Self.maximumOutboundFrameBytes
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteGatewayTransportError.nonUTF8Payload
        }
        try await transport.send(.text(text))
    }

    private func updateState(_ newState: RemoteGatewayState) {
        guard state != newState else { return }
        state = newState
        guard let stateObserver else { return }
        Task { @MainActor in stateObserver(newState) }
    }

    private static func publicErrorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: type(of: error))
    }
}
