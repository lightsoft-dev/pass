import Foundation

/// Production bridge to the same stores and reply path used by the desktop UI.
@MainActor
final class AppRemoteCommandBackend: RemoteCommandBackend {
    private weak var appModel: AppModel?

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func currentSessions() -> [RemoteSessionDTO] {
        guard let appModel, appModel.isReady, let sessions = appModel.sessions else { return [] }
        return sessions.sessions.map(RemoteSessionDTO.init)
    }

    func currentProjects() -> [RemoteProjectDTO] {
        guard let appModel, appModel.isReady, let projects = appModel.projects else { return [] }
        return projects.projects.map(RemoteProjectDTO.init)
    }

    func createSession(_ command: RemoteSessionCreateCommand) async throws -> String {
        guard let appModel, appModel.isReady,
              let sessions = appModel.sessions,
              let projects = appModel.projects else {
            throw RemoteExecutionError(code: "desktop_not_ready", message: "The desktop is still starting.", retryable: true)
        }

        let projectRoot = command.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard projects.projects.contains(where: { $0.rootPath == projectRoot }) else {
            throw RemoteExecutionError(
                code: "project_not_registered",
                message: "The requested project is not registered on this desktop."
            )
        }

        let agent = command.agent.localKind
        guard AgentKind.launchable.contains(agent) else {
            throw RemoteExecutionError(code: "agent_not_launchable", message: "That agent cannot start a new session.")
        }

        let sessionName = await sessions.createSession(
            projectDir: projectRoot,
            agent: agent,
            initialPrompt: command.initialPrompt
        )
        guard sessions.session(named: sessionName) != nil else {
            throw RemoteExecutionError(
                code: "session_create_failed",
                message: "The desktop could not start the requested session.",
                retryable: true
            )
        }
        return sessionName
    }

    func sendMessage(_ command: RemoteSessionSendMessageCommand) async throws {
        guard let appModel, appModel.isReady, let sessions = appModel.sessions else {
            throw RemoteExecutionError(code: "desktop_not_ready", message: "The desktop is still starting.", retryable: true)
        }
        guard let session = sessions.session(named: command.session) else {
            throw RemoteExecutionError(code: "session_not_found", message: "The requested session is not running.")
        }
        guard session.agent != .shell else {
            throw RemoteExecutionError(
                code: "delivery_refused",
                message: "Messages cannot be injected into a bare shell."
            )
        }

        switch await appModel.reply(to: session.name, text: command.text) {
        case .delivered:
            return
        case .refusedShell:
            throw RemoteExecutionError(
                code: "delivery_refused",
                message: "The agent is no longer accepting messages."
            )
        case .error(let message):
            throw RemoteExecutionError(code: "delivery_failed", message: message, retryable: true)
        }
    }

    func answerDecision(_ command: RemoteSessionAnswerDecisionCommand) async throws {
        guard let appModel, appModel.isReady, let sessions = appModel.sessions else {
            throw RemoteExecutionError(code: "desktop_not_ready", message: "The desktop is still starting.", retryable: true)
        }
        guard let session = sessions.session(named: command.session) else {
            throw RemoteExecutionError(code: "session_not_found", message: "The requested session is not running.")
        }
        guard case .pending(let attention) = session.attention, attention.kind == .decision else {
            throw RemoteExecutionError(
                code: "decision_not_pending",
                message: "The session is not waiting on a decision."
            )
        }
        guard session.agent != .shell else {
            throw RemoteExecutionError(
                code: "delivery_refused",
                message: "Decisions cannot be injected into a bare shell."
            )
        }

        let decision: ReplyInjector.Decision
        switch command.decision {
        case .allowOnce: decision = .allowOnce
        case .allowAll: decision = .allowAll
        case .deny: decision = .deny
        }

        switch await ReplyInjector.shared.sendDecision(session.name, agent: session.agent, decision) {
        case .delivered:
            sessions.acknowledge(session.name)
            sessions.applyAttention(name: session.name, .working)
        case .refusedShell:
            throw RemoteExecutionError(
                code: "delivery_refused",
                message: "The agent is no longer accepting decisions."
            )
        case .error(let message):
            throw RemoteExecutionError(code: "delivery_failed", message: message, retryable: true)
        }
    }

    func openTerminal(_ command: RemoteSessionTerminalOpenCommand) async throws -> RemoteSessionTerminalSnapshot {
        guard let appModel, appModel.isReady, let sessions = appModel.sessions else {
            throw RemoteExecutionError(code: "desktop_not_ready", message: "The desktop is still starting.", retryable: true)
        }
        guard sessions.session(named: command.session) != nil else {
            throw RemoteExecutionError(code: "session_not_found", message: "The requested session is not running.")
        }
        guard let snapshot = await appModel.openRemoteTerminal(command) else {
            throw RemoteExecutionError(code: "terminal_unavailable", message: "The tmux pane could not be captured.", retryable: true)
        }
        return snapshot
    }

    func sendTerminalInput(_ command: RemoteSessionTerminalInputCommand) async throws {
        guard let appModel, appModel.isReady, let sessions = appModel.sessions else {
            throw RemoteExecutionError(code: "desktop_not_ready", message: "The desktop is still starting.", retryable: true)
        }
        guard sessions.session(named: command.session) != nil else {
            throw RemoteExecutionError(code: "session_not_found", message: "The requested session is not running.")
        }
        guard await appModel.sendRemoteTerminalInput(command) else {
            throw RemoteExecutionError(
                code: "terminal_not_open",
                message: "The terminal subscription expired. Reopen it and retry.",
                retryable: true
            )
        }
    }

    func closeTerminal(_ command: RemoteSessionTerminalCloseCommand) async throws {
        guard let appModel, appModel.isReady else {
            throw RemoteExecutionError(code: "desktop_not_ready", message: "The desktop is still starting.", retryable: true)
        }
        await appModel.closeRemoteTerminal(command)
    }
}
