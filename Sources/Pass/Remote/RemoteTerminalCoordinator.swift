import Foundation

typealias RemoteTerminalPublisher = @Sendable (RemoteSessionTerminalSnapshot) async -> Void

actor RemoteTerminalCoordinator {
    private struct Subscription: Sendable {
        var session: String
        var expiresAt: Date
        var lastRevision: String
    }

    private let panes: any TerminalPaneAccess
    private let publisher: RemoteTerminalPublisher
    private let now: @Sendable () -> Date
    private let subscriptionLifetime: TimeInterval
    private let refreshInterval: Duration

    private var subscriptions: [String: Subscription] = [:]
    private var streamTask: Task<Void, Never>?

    init(
        panes: any TerminalPaneAccess = TmuxClient.shared,
        subscriptionLifetime: TimeInterval = 30,
        refreshInterval: Duration = .milliseconds(120),
        now: @escaping @Sendable () -> Date = { Date() },
        publisher: @escaping RemoteTerminalPublisher
    ) {
        self.panes = panes
        self.publisher = publisher
        self.now = now
        self.subscriptionLifetime = subscriptionLifetime
        self.refreshInterval = refreshInterval
    }

    func open(
        session: String,
        subscriptionID: String,
        previousRevision: String?
    ) async -> RemoteSessionTerminalSnapshot? {
        guard let pane = await panes.terminalSnapshot(session) else { return nil }
        let revision = Self.revision(for: pane)
        subscriptions[subscriptionID] = Subscription(
            session: session,
            expiresAt: now().addingTimeInterval(subscriptionLifetime),
            lastRevision: revision
        )
        startStreamingIfNeeded()
        return RemoteSessionTerminalSnapshot(
            session: session,
            subscriptionID: subscriptionID,
            revision: revision,
            pane: pane,
            omitContent: previousRevision == revision
        )
    }

    func sendInput(session: String, subscriptionID: String, input: String) async -> Bool {
        guard let subscription = activeSubscription(subscriptionID),
              subscription.session == session else {
            return false
        }
        return await panes.sendTerminalInput(input, to: session)
    }

    func close(session: String, subscriptionID: String) {
        guard subscriptions[subscriptionID]?.session == session else { return }
        subscriptions.removeValue(forKey: subscriptionID)
        if subscriptions.isEmpty {
            streamTask?.cancel()
            streamTask = nil
        }
    }

    func stop() {
        subscriptions.removeAll()
        streamTask?.cancel()
        streamTask = nil
    }

    private func activeSubscription(_ id: String) -> Subscription? {
        guard let subscription = subscriptions[id] else { return nil }
        guard subscription.expiresAt > now() else {
            subscriptions.removeValue(forKey: id)
            return nil
        }
        return subscription
    }

    private func startStreamingIfNeeded() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            await self?.streamChanges()
        }
    }

    private func streamChanges() async {
        while !Task.isCancelled {
            let currentDate = now()
            subscriptions = subscriptions.filter { $0.value.expiresAt > currentDate }
            guard !subscriptions.isEmpty else { break }

            let sessions = Set(subscriptions.values.map(\.session))
            var panesBySession: [String: TerminalPaneSnapshot] = [:]
            for session in sessions {
                if let pane = await panes.terminalSnapshot(session) {
                    panesBySession[session] = pane
                }
            }

            for (subscriptionID, subscription) in subscriptions {
                guard let pane = panesBySession[subscription.session] else { continue }
                let revision = Self.revision(for: pane)
                guard revision != subscription.lastRevision else { continue }
                subscriptions[subscriptionID]?.lastRevision = revision
                await publisher(RemoteSessionTerminalSnapshot(
                    session: subscription.session,
                    subscriptionID: subscriptionID,
                    revision: revision,
                    pane: pane
                ))
            }

            try? await Task.sleep(for: refreshInterval)
        }
        streamTask = nil
    }

    private static func revision(for pane: TerminalPaneSnapshot) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        pane.content.utf8.forEach(mix)
        "\(pane.columns),\(pane.rows),\(pane.cursorX),\(pane.cursorY)".utf8.forEach(mix)
        return String(format: "%016llx", hash)
    }
}
