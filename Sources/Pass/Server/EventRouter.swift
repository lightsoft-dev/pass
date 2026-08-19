import Foundation

/// Turns normalized AgentEvents into state-machine transitions + notifications. Agent-agnostic:
/// it only sees AgentEvent, never hook payloads.
@MainActor
final class EventRouter {
    private let sessions: SessionStore
    /// Called when a session enters/updates a needs-you (or finished) state. @MainActor so the
    /// wiring in AppDelegate can touch main-actor state (extension runtime) directly.
    private let onAttention: @MainActor (_ name: String, _ display: String, _ attention: Attention) -> Void
    /// Called when a session no longer needs the user (started/ended) — clear its notifications.
    private let onResolved: @MainActor (_ name: String) -> Void

    init(sessions: SessionStore,
         onAttention: @escaping @MainActor (String, String, Attention) -> Void,
         onResolved: @escaping @MainActor (String) -> Void) {
        self.sessions = sessions
        self.onAttention = onAttention
        self.onResolved = onResolved
    }

    func route(path: String, raw: RawHookEvent) {
        guard let adapter = AgentRegistry.adapter(forRoute: path) else {
            Log.hooks.debug("no adapter for route \(path, privacy: .public)"); return
        }
        guard let event = adapter.normalize(raw) else { return } // ignored event (e.g. SessionStart)

        guard let name = sessions.resolveSessionName(hint: event.sessionNameHint, cwd: event.cwd) else {
            Log.hooks.debug("dropped unmapped \(raw.eventName, privacy: .public) hint=\(event.sessionNameHint ?? "-", privacy: .public)")
            return
        }

        // Grok can import Claude-compatible hooks in addition to its own global hooks. Drop a
        // compatibility copy when its route disagrees with the agent actually owning the pane.
        // This also prevents any future cross-provider compatibility layer from double-routing.
        let sessionAgent = sessions.session(named: name)?.agent
        if let sessionAgent,
           AgentKind.launchable.contains(sessionAgent),
           adapter.kind != sessionAgent {
            Log.hooks.debug("dropped \(raw.eventName, privacy: .public) from mismatched \(adapter.kind.rawValue, privacy: .public) route for \(sessionAgent.rawValue, privacy: .public) session")
            return
        }
        let agentLabel = sessionAgent?.rawValue.capitalized ?? "Agent"

        let now = Date()
        switch event.kind {
        case .started:
            sessions.applyAttention(name: name, .working)
            onResolved(name)
        case .ended:
            sessions.applyAttention(name: name, .idle)
            onResolved(name)
        case .needsDecision:
            emit(name, Attention(kind: .decision, receivedAt: now, preview: event.preview ?? "\(agentLabel) needs your permission"))
        case .needsInput:
            emit(name, Attention(kind: .input, receivedAt: now, preview: event.preview ?? "\(agentLabel) needs your input"))
        case .finished:
            if let msg = event.preview, !msg.isEmpty { sessions.setLastMessage(name: name, msg) }
            emit(name, Attention(kind: .finished, receivedAt: now, preview: event.preview ?? "Finished"))
        }
        Log.hooks.info("event \(raw.eventName, privacy: .public) -> \(name, privacy: .public)")
    }

    private func emit(_ name: String, _ attention: Attention) {
        sessions.applyAttention(name: name, .pending(attention))
        let display = sessions.session(named: name)?.displayName ?? name
        onAttention(name, display, attention)
    }
}
