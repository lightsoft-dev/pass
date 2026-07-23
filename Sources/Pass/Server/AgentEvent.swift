import Foundation

/// Raw hook payload as received by HookServer, before agent-specific interpretation.
/// Decodes only the fields pass understands; tolerant of schema drift (unknown fields ignored).
struct RawHookEvent: Sendable {
    var eventName: String
    var sessionId: String?
    var cwd: String?
    var notificationType: String?
    var toolName: String?
    var lastAssistantMessage: String?
    var reason: String?
    /// tmux session name from the X-Pass-Session header (primary routing key).
    var passSessionHeader: String?

    init(json: [String: Any], header: String?) {
        self.eventName = (json["hook_event_name"] as? String) ?? ""
        self.sessionId = json["session_id"] as? String
        self.cwd = json["cwd"] as? String
        self.notificationType = json["notification_type"] as? String
        self.toolName = json["tool_name"] as? String
        self.lastAssistantMessage = json["last_assistant_message"] as? String
        self.reason = json["reason"] as? String
        self.passSessionHeader = (header?.isEmpty == false) ? header : nil
    }
}

/// Normalized, agent-independent event. The core (EventRouter/state machine) only sees this.
struct AgentEvent: Sendable {
    enum Kind: Sendable { case needsDecision, needsInput, finished, started, ended }
    var kind: Kind
    var preview: String?
    // Routing hints (EventRouter resolves these to a session).
    var sessionNameHint: String?
    var cwd: String?
    var agentSessionId: String?
}

/// Agent knowledge lives only in adapters. The core is agent-agnostic.
protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    /// HookServer route this agent's push signals arrive on, e.g. "/hook/claude".
    var routePath: String { get }
    func normalize(_ raw: RawHookEvent) -> AgentEvent?
}

/// Claude Code hooks → AgentEvent. Mapping validated in spikes/FINDINGS.md.
struct ClaudeAdapter: AgentAdapter {
    let kind: AgentKind = .claude
    let routePath = "/hook/claude"

    func normalize(_ raw: RawHookEvent) -> AgentEvent? {
        let kind: AgentEvent.Kind
        var preview: String?
        switch raw.eventName {
        case "Notification":
            switch raw.notificationType {
            case "permission_prompt":
                kind = .needsDecision
            case "idle_prompt", "agent_needs_input", "elicitation_dialog":
                kind = .needsInput
            default:
                kind = .needsInput // tolerant: unknown notification type → needs input
            }
        case "Stop":
            kind = .finished
            preview = raw.lastAssistantMessage
        case "UserPromptSubmit":
            kind = .started
        case "SessionEnd":
            kind = .ended
        default:
            return nil // SessionStart etc. — ignored
        }
        return AgentEvent(kind: kind, preview: preview,
                          sessionNameHint: raw.passSessionHeader,
                          cwd: raw.cwd, agentSessionId: raw.sessionId)
    }
}

/// Codex command hooks use the same common event fields as Claude hooks but expose approval
/// requests as PermissionRequest. Command hook stdin is forwarded unchanged by the installer.
struct CodexAdapter: AgentAdapter {
    let kind: AgentKind = .codex
    let routePath = "/hook/codex"

    func normalize(_ raw: RawHookEvent) -> AgentEvent? {
        let kind: AgentEvent.Kind
        var preview = raw.lastAssistantMessage
        switch raw.eventName {
        case "PermissionRequest":
            kind = .needsDecision
            if preview == nil, let toolName = raw.toolName {
                preview = "Approval requested for \(toolName)"
            }
        case "UserPromptSubmit", "SessionStart":
            kind = .started
        case "Stop":
            kind = .finished
        default:
            return nil
        }
        return AgentEvent(kind: kind, preview: preview,
                          sessionNameHint: raw.passSessionHeader,
                          cwd: raw.cwd, agentSessionId: raw.sessionId)
    }
}

/// The installed pi extension emits the normalized lifecycle names below. pi intentionally has
/// no built-in permission prompts, so its bridge covers start, input, completion, and shutdown.
struct PiAdapter: AgentAdapter {
    let kind: AgentKind = .pi
    let routePath = "/hook/pi"

    func normalize(_ raw: RawHookEvent) -> AgentEvent? {
        let kind: AgentEvent.Kind
        switch raw.eventName {
        case "SessionStart", "UserPromptSubmit": kind = .started
        case "Stop": kind = .finished
        case "SessionEnd": kind = .ended
        default: return nil
        }
        return AgentEvent(kind: kind, preview: raw.lastAssistantMessage,
                          sessionNameHint: raw.passSessionHeader,
                          cwd: raw.cwd, agentSessionId: raw.sessionId)
    }
}

enum AgentRegistry {
    static let all: [AgentAdapter] = [ClaudeAdapter(), CodexAdapter(), PiAdapter()]
    static func adapter(forRoute path: String) -> AgentAdapter? {
        all.first { $0.routePath == path }
    }
}
