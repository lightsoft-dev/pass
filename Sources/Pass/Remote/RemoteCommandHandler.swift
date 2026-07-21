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
    func openTerminal(_ command: RemoteSessionTerminalOpenCommand) async throws -> RemoteSessionTerminalSnapshot
    func sendTerminalInput(_ command: RemoteSessionTerminalInputCommand) async throws
    func closeTerminal(_ command: RemoteSessionTerminalCloseCommand) async throws
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
    static let maximumSubscriptionIDCharacters = 128

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

        case .sessionTerminalOpen(let command):
            guard validSession(command.session) else {
                return [failure(replyTo: envelope.id, code: "invalid_session", message: "A valid session name is required.")]
            }
            guard validSubscriptionID(command.subscriptionID) else {
                return [failure(replyTo: envelope.id, code: "invalid_subscription", message: "A valid terminal subscription id is required.")]
            }
            do {
                var normalized = command
                normalized.session = command.session.trimmingCharacters(in: .whitespacesAndNewlines)
                let snapshot = try await backend.openTerminal(normalized)
                return [
                    acknowledgement(for: envelope, resourceID: normalized.subscriptionID),
                    event(replyTo: envelope.id, .sessionTerminalSnapshot(snapshot)),
                ]
            } catch {
                return [failure(for: error, replyTo: envelope.id)]
            }

        case .sessionTerminalInput(let command):
            guard validSession(command.session) else {
                return [failure(replyTo: envelope.id, code: "invalid_session", message: "A valid session name is required.")]
            }
            guard validSubscriptionID(command.subscriptionID) else {
                return [failure(replyTo: envelope.id, code: "invalid_subscription", message: "A valid terminal subscription id is required.")]
            }
            guard !command.input.isEmpty else {
                return [failure(replyTo: envelope.id, code: "invalid_terminal_input", message: "Terminal input cannot be empty.")]
            }
            guard command.input.utf8.count <= RemoteWireLimits.terminalInputBytes else {
                return [failure(replyTo: envelope.id, code: "terminal_input_too_large", message: "Terminal input is too large.")]
            }
            do {
                var normalized = command
                normalized.session = command.session.trimmingCharacters(in: .whitespacesAndNewlines)
                try await backend.sendTerminalInput(normalized)
                return [acknowledgement(for: envelope, resourceID: normalized.subscriptionID)]
            } catch {
                return [failure(for: error, replyTo: envelope.id)]
            }

        case .sessionTerminalClose(let command):
            guard validSession(command.session) else {
                return [failure(replyTo: envelope.id, code: "invalid_session", message: "A valid session name is required.")]
            }
            guard validSubscriptionID(command.subscriptionID) else {
                return [failure(replyTo: envelope.id, code: "invalid_subscription", message: "A valid terminal subscription id is required.")]
            }
            do {
                var normalized = command
                normalized.session = command.session.trimmingCharacters(in: .whitespacesAndNewlines)
                try await backend.closeTerminal(normalized)
                return [acknowledgement(for: envelope, resourceID: normalized.subscriptionID)]
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
                .sessionsTerminal,
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

    private func validSession(_ session: String) -> Bool {
        let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= Self.maximumSessionNameCharacters
    }

    private func validSubscriptionID(_ id: String) -> Bool {
        guard id.count <= Self.maximumSubscriptionIDCharacters else { return false }
        return id.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
            options: .regularExpression
        ) != nil
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
