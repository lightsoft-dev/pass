import Foundation

struct RemoteExecutionError: Error, Equatable, Sendable {
    var code: String
    var message: String
    var retryable: Bool

    init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// Narrow desktop surface exposed to remote commands. The relay never receives a tmux client,
/// filesystem service, or arbitrary command runner; it can only invoke these explicit actions.
@MainActor
protocol RemoteCommandBackend: AnyObject {
    func currentSessions() -> [RemoteSessionDTO]
    func currentProjects() -> [RemoteProjectDTO]
    func createSession(_ command: RemoteSessionCreateCommand) async throws -> String
    func sendMessage(_ command: RemoteSessionSendMessageCommand) async throws
    func answerDecision(_ command: RemoteSessionAnswerDecisionCommand) async throws
}

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
}

@MainActor
protocol RemoteCommandHandling: AnyObject, Sendable {
    func handle(_ envelope: RemoteCommandEnvelope) async -> [RemoteEventEnvelope]
    func makeSnapshotEvent(replyTo: String?) -> RemoteEventEnvelope
}

/// Validates protocol commands, invokes the narrow backend, and guarantees an ack or error for
/// every well-formed command. Follow-up domain events share the command id through `replyTo`.
@MainActor
final class RemoteCommandHandler: RemoteCommandHandling {
    static let maximumIdentifierCharacters = 128
    static let maximumTypeCharacters = 128
    static let maximumPathCharacters = 4_096
    static let maximumSessionNameCharacters = 300
    static let maximumMessageCharacters = 64 * 1_024
    static let maximumInitialPromptCharacters = 64 * 1_024

    private let backend: any RemoteCommandBackend
    private let now: () -> Date
    private let makeID: () -> String

    init(
        backend: any RemoteCommandBackend,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> String = { "evt_\(UUID().uuidString.lowercased())" }
    ) {
        self.backend = backend
        self.now = now
        self.makeID = makeID
    }

    func handle(_ envelope: RemoteCommandEnvelope) async -> [RemoteEventEnvelope] {
        guard RemoteProtocolVersion.supported.contains(envelope.version) else {
            return [failure(
                replyTo: envelope.id,
                code: "unsupported_protocol_version",
                message: "Desktop supports remote protocol version \(RemoteProtocolVersion.current)."
            )]
        }
        guard !envelope.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              envelope.id.count <= Self.maximumIdentifierCharacters else {
            return [failure(replyTo: nil, code: "invalid_command", message: "A valid command id is required.")]
        }
        guard envelope.type.count <= Self.maximumTypeCharacters else {
            return [failure(
                replyTo: envelope.id,
                code: "invalid_command",
                message: "Command type is too large."
            )]
        }

        switch envelope.command {
        case .sessionList, .projectList:
            return [
                acknowledgement(for: envelope),
                makeSnapshotEvent(replyTo: envelope.id),
            ]

        case .sessionCreate(let command):
            let root = command.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !root.isEmpty else {
                return [failure(replyTo: envelope.id, code: "invalid_project", message: "Project root is required.")]
            }
            guard root.count <= Self.maximumPathCharacters else {
                return [failure(replyTo: envelope.id, code: "invalid_project", message: "Project root is too large.")]
            }
            guard command.agent != .shell, command.agent != .generic else {
                return [failure(
                    replyTo: envelope.id,
                    code: "agent_not_launchable",
                    message: "That agent cannot start a new session."
                )]
            }
            if let prompt = command.initialPrompt,
               prompt.count > Self.maximumInitialPromptCharacters {
                return [failure(
                    replyTo: envelope.id,
                    code: "initial_prompt_too_large",
                    message: "Initial prompt is too large."
                )]
            }

            do {
                var normalized = command
                normalized.projectRoot = root
                let sessionName = try await backend.createSession(normalized)
                return [
                    acknowledgement(for: envelope, resourceID: sessionName),
                    makeSnapshotEvent(replyTo: envelope.id),
                ]
            } catch {
                return [failure(for: error, replyTo: envelope.id)]
            }

        case .sessionSendMessage(let command):
            let session = command.session.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !session.isEmpty else {
                return [failure(replyTo: envelope.id, code: "invalid_session", message: "Session name is required.")]
            }
            guard session.count <= Self.maximumSessionNameCharacters else {
                return [failure(replyTo: envelope.id, code: "invalid_session", message: "Session name is too large.")]
            }
            guard !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return [failure(replyTo: envelope.id, code: "invalid_message", message: "Message text is required.")]
            }
            guard command.text.count <= Self.maximumMessageCharacters else {
                return [failure(replyTo: envelope.id, code: "message_too_large", message: "Message is too large.")]
            }

            do {
                var normalized = command
                normalized.session = session
                try await backend.sendMessage(normalized)
                return [
                    acknowledgement(for: envelope),
                    event(
                        replyTo: envelope.id,
                        .messageDelivered(RemoteMessageDelivered(session: session))
                    ),
                ]
            } catch {
                return [failure(for: error, replyTo: envelope.id)]
            }

        case .sessionAnswerDecision(let command):
            let session = command.session.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !session.isEmpty else {
                return [failure(replyTo: envelope.id, code: "invalid_session", message: "Session name is required.")]
            }
            guard session.count <= Self.maximumSessionNameCharacters else {
                return [failure(replyTo: envelope.id, code: "invalid_session", message: "Session name is too large.")]
            }

            do {
                var normalized = command
                normalized.session = session
                try await backend.answerDecision(normalized)
                return [
                    acknowledgement(for: envelope),
                    makeSnapshotEvent(replyTo: envelope.id),
                ]
            } catch {
                return [failure(for: error, replyTo: envelope.id)]
            }

        case .unsupported(let type, _):
            return [failure(
                replyTo: envelope.id,
                code: "unsupported_command",
                message: "Desktop does not support command type \(type)."
            )]
        }
    }

    func makeSnapshotEvent(replyTo: String? = nil) -> RemoteEventEnvelope {
        let snapshot = RemoteSessionSnapshot(
            generatedAt: now(),
            sessions: backend.currentSessions(),
            projects: backend.currentProjects(),
            capabilities: [
                .sessionsRead,
                .sessionsWrite,
                .sessionsStream,
                .projectsRead,
                .decisionsAnswer,
            ]
        )
        return event(replyTo: replyTo, .sessionSnapshot(snapshot))
    }

    private func acknowledgement(
        for command: RemoteCommandEnvelope,
        resourceID: String? = nil
    ) -> RemoteEventEnvelope {
        event(
            replyTo: command.id,
            .acknowledgement(RemoteAcknowledgement(commandType: command.type, resourceID: resourceID))
        )
    }

    private func failure(for error: Error, replyTo: String?) -> RemoteEventEnvelope {
        if let error = error as? RemoteExecutionError {
            return failure(
                replyTo: replyTo,
                code: error.code,
                message: error.message,
                retryable: error.retryable
            )
        }
        return failure(
            replyTo: replyTo,
            code: "command_failed",
            message: "The desktop could not complete the command.",
            retryable: true
        )
    }

    private func failure(
        replyTo: String?,
        code: String,
        message: String,
        retryable: Bool = false
    ) -> RemoteEventEnvelope {
        event(
            replyTo: replyTo,
            .error(RemoteCommandFailure(code: code, message: message, retryable: retryable))
        )
    }

    private func event(replyTo: String?, _ event: RemoteEvent) -> RemoteEventEnvelope {
        RemoteEventEnvelope(id: makeID(), sentAt: now(), replyTo: replyTo, event: event)
    }
}

protocol RemoteSnapshotPublishing: Sendable {
    func publishSnapshot() async
}

/// Main-actor bridge for `SessionStore` and `EventRouter` callbacks. Reconcile invokes its hook
/// before assigning the final session array, so this intentionally publishes on a later turn and
/// coalesces bursts of session/attention updates.
@MainActor
final class RemoteSnapshotPublicationHook {
    private let publisher: any RemoteSnapshotPublishing
    private let debounceNanoseconds: UInt64
    private var pendingTask: Task<Void, Never>?

    init(
        publisher: any RemoteSnapshotPublishing,
        debounceNanoseconds: UInt64 = 50_000_000
    ) {
        self.publisher = publisher
        self.debounceNanoseconds = debounceNanoseconds
    }

    func schedule() {
        pendingTask?.cancel()
        let publisher = self.publisher
        let delay = debounceNanoseconds
        pendingTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            await publisher.publishSnapshot()
        }
    }

    func publishNow() {
        pendingTask?.cancel()
        let publisher = self.publisher
        pendingTask = Task { await publisher.publishSnapshot() }
    }
}
