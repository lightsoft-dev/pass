import Foundation
import Observation

enum RemoteControllerConnectionState: Equatable, Sendable {
    case connecting
    case online
    case hostOffline
    case error(String)
}

/// One outbound controller connection to another Pass desktop owned by the same account.
/// The remote host remains authoritative; this object only holds its latest bounded snapshot.
@MainActor
@Observable
final class RemoteControllerConnection: Identifiable {
    nonisolated let id: String
    private(set) var profile: RemoteControllerProfile
    private(set) var state: RemoteControllerConnectionState = .connecting
    private(set) var sessions: [RemoteSessionDTO] = []
    private(set) var projects: [RemoteProjectDTO] = []
    private(set) var capabilities: [RemoteCapability] = []
    private(set) var terminalSnapshots: [String: RemoteSessionTerminalSnapshot] = [:]
    private(set) var lastCommandError: String?

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var stopped = true
    @ObservationIgnored private let profileChanged: @MainActor (RemoteControllerProfile) -> Void

    init(
        profile: RemoteControllerProfile,
        profileChanged: @escaping @MainActor (RemoteControllerProfile) -> Void
    ) {
        id = profile.desktopID
        self.profile = profile
        self.profileChanged = profileChanged
    }

    func start() {
        stopped = false
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in await self?.open() }
    }

    func stop() {
        stopped = true
        receiveTask?.cancel()
        reconnectTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    func refresh() { send(.sessionList); send(.projectList) }

    func sendMessage(session: String, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(.sessionSendMessage(.init(session: session, text: text)))
    }

    func answerDecision(session: String, decision: RemoteDecision) {
        send(.sessionAnswerDecision(.init(session: session, decision: decision)))
    }

    func openTerminal(session: String) {
        let previous = terminalSnapshots[session]?.revision
        send(.sessionTerminalOpen(.init(
            session: session,
            subscriptionID: subscriptionID(for: session),
            previousRevision: previous
        )))
    }

    func sendTerminalInput(session: String, input: String) {
        guard !input.isEmpty else { return }
        send(.sessionTerminalInput(.init(
            session: session,
            subscriptionID: subscriptionID(for: session),
            input: input
        )))
    }

    func closeTerminal(session: String) {
        send(.sessionTerminalClose(.init(
            session: session,
            subscriptionID: subscriptionID(for: session)
        )))
    }

    private func subscriptionID(for session: String) -> String {
        "mac:\(profile.deviceID):\(session)"
    }

    private func open() async {
        guard !stopped else { return }
        state = .connecting
        do {
            try await refreshCredentialIfNeeded()
            guard !stopped else { return }
            var request = URLRequest(url: try socketURL(profile.relayURL))
            request.setValue("Bearer \(profile.credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("1", forHTTPHeaderField: "X-Pass-Protocol-Version")
            request.setValue(profile.desktopID, forHTTPHeaderField: "X-Pass-Desktop-ID")
            request.setValue("mobile", forHTTPHeaderField: "X-Pass-Role")
            request.setValue(profile.deviceID, forHTTPHeaderField: "X-Pass-Device-ID")
            let task = URLSession.shared.webSocketTask(with: request)
            socket = task
            task.resume()
            receiveTask?.cancel()
            receiveTask = Task { [weak self, weak task] in
                guard let self, let task else { return }
                await self.receiveLoop(task)
            }
        } catch {
            state = .error(error.localizedDescription)
            scheduleReconnect()
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled, !stopped, socket === task {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                handle(data)
            }
        } catch {
            guard !stopped, socket === task else { return }
            socket = nil
            state = .error(error.localizedDescription)
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.open()
        }
    }

    private func handle(_ data: Data) {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String {
            if type == "relay.ready" {
                state = .hostOffline
                refresh()
                return
            }
            if type == "desktop.presence",
               let payload = object["payload"] as? [String: Any] {
                let online = payload["desktopOnline"] as? Bool == true
                state = online ? .online : .hostOffline
                if online { refresh() }
                return
            }
            if type.hasPrefix("relay.") { return }
        }

        guard let envelope = try? RemoteWireCodec.decodeEvent(from: data) else { return }
        switch envelope.event {
        case .sessionSnapshot(let snapshot):
            sessions = snapshot.sessions
            projects = snapshot.projects
            capabilities = snapshot.capabilities
        case .sessionMessageStarted(let stream), .sessionMessageUpdated(let stream):
            updateSession(stream.session) { session in
                session.liveMessage = stream.text
                session.liveMessageTruncated = stream.truncated ? true : nil
                session.attention = .init(status: .working)
            }
        case .sessionMessageCompleted(let stream):
            updateSession(stream.session) { session in
                session.lastMessage = stream.text
                session.liveMessage = nil
                session.liveMessageTruncated = nil
                session.attention = .init(status: .idle)
                session.lastActivity = Date()
            }
        case .sessionTerminalSnapshot(var snapshot):
            if snapshot.content == nil { snapshot.content = terminalSnapshots[snapshot.session]?.content }
            terminalSnapshots[snapshot.session] = snapshot
        case .messageDelivered, .acknowledgement:
            send(.sessionList)
        case .error(let failure):
            lastCommandError = failure.message
        case .unsupported:
            break
        }
    }

    private func updateSession(_ name: String, mutate: (inout RemoteSessionDTO) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.name == name }) else { return }
        mutate(&sessions[index])
    }

    private func send(_ command: RemoteCommand) {
        guard let socket else { return }
        let envelope = RemoteCommandEnvelope(
            id: "mac_\(UUID().uuidString.lowercased())",
            sentAt: Date(),
            command: command
        )
        guard let data = try? RemoteWireCodec.encode(envelope) else { return }
        Task {
            do { try await socket.send(.data(data)) }
            catch {
                guard !stopped else { return }
                state = .error(error.localizedDescription)
                scheduleReconnect()
            }
        }
    }

    private func refreshCredentialIfNeeded() async throws {
        if let expiration = profile.credentials.accessExpiration,
           expiration > Date().addingTimeInterval(60) { return }
        var request = URLRequest(url: profile.relayURL.appending(path: "v2/token/refresh"))
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(profile.credentials.refreshToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let refreshed = try? JSONDecoder().decode(ControllerCredentialResponse.self, from: data) else {
            throw RemoteAccountError.authorizationFailed("Could not refresh access to \(profile.desktopName).")
        }
        profile.credentials = refreshed.credentials
        profileChanged(profile)
    }

    private func socketURL(_ relayURL: URL) throws -> URL {
        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else {
            throw RemoteAccountError.invalidServerResponse
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = base.hasSuffix("connect") ? "/\(base)" : "/\(base.isEmpty ? "connect" : "\(base)/connect")"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw RemoteAccountError.invalidServerResponse }
        return url
    }
}

@MainActor
@Observable
final class RemoteControllerStore {
    private(set) var connections: [RemoteControllerConnection] = []

    var sessionCount: Int { connections.reduce(0) { $0 + $1.sessions.count } }

    func install(profiles: [RemoteControllerProfile]) {
        connections.forEach { $0.stop() }
        connections = profiles.map { profile in
            RemoteControllerConnection(profile: profile) { [weak self] updated in
                self?.persist(updated)
            }
        }
        connections.forEach { $0.start() }
    }

    func stop() {
        connections.forEach { $0.stop() }
        connections = []
    }

    private func persist(_ updated: RemoteControllerProfile) {
        guard var profiles = try? RemoteCredentialStore.loadControllerProfiles(),
              let index = profiles.firstIndex(where: { $0.desktopID == updated.desktopID }) else { return }
        profiles[index] = updated
        try? RemoteCredentialStore.saveControllerProfiles(profiles)
    }
}

private struct ControllerCredentialResponse: Decodable {
    let credentials: RemoteCredentialPair
}
