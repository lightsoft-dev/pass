import Foundation

/// Wire-level versioning for the mobile/desktop control protocol. Increment this only for a
/// breaking envelope or payload change; additive fields remain compatible within version 1.
enum RemoteProtocolVersion {
    static let current = 1
    static let supported = 1...1
}

enum RemoteWireLimits {
    /// Leaves room below the relay/mobile 1 MiB control-frame ceiling for transport variance.
    static let maximumOutboundFrameBytes = 900_000
    static let maximumSnapshotItems = 500
    static let sessionNameBytes = 300
    static let displayNameBytes = 500
    static let pathBytes = 4_096
    static let branchBytes = 500
    static let attentionPreviewBytes = 4_096
    static let lastMessageBytes = 8_192
    static let streamMessageBytes = 64 * 1_024
    static let terminalSnapshotBytes = 512 * 1_024
    static let terminalInputBytes = 16 * 1_024
    static let projectNameBytes = 500
    static let emojiBytes = 32

    static func prefix(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes > 0 else { return "" }
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        var result = ""
        var usedBytes = 0
        for character in value {
            let fragment = String(character)
            let bytes = fragment.utf8.count
            guard usedBytes + bytes <= maximumUTF8Bytes else { break }
            result.append(character)
            usedBytes += bytes
        }
        guard result.isEmpty else { return result }

        // A single extended grapheme can exceed the entire wire budget (for example an ASCII
        // base followed by hundreds of combining marks). Fall back to Unicode-scalar boundaries
        // so a non-empty source does not become an invalid empty required field on the wire.
        var scalarResult = ""
        usedBytes = 0
        for scalar in value.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard usedBytes + bytes <= maximumUTF8Bytes else { break }
            scalarResult.append(contentsOf: fragment)
            usedBytes += bytes
        }
        return scalarResult
    }

    static func optionalPrefix(_ value: String?, maximumUTF8Bytes: Int) -> String? {
        value.map { prefix($0, maximumUTF8Bytes: maximumUTF8Bytes) }
    }
}

enum RemoteCommandType {
    static let sessionList = "session.list"
    static let sessionCreate = "session.create"
    static let sessionSendMessage = "session.sendMessage"
    static let sessionAnswerDecision = "session.answerDecision"
    static let sessionTerminalOpen = "session.terminal.open"
    static let sessionTerminalInput = "session.terminal.input"
    static let sessionTerminalClose = "session.terminal.close"
    static let projectList = "project.list"
}

enum RemoteEventType {
    static let acknowledgement = "ack"
    static let error = "error"
    static let sessionSnapshot = "session.snapshot"
    static let messageDelivered = "message.delivered"
    static let sessionMessageStarted = "session.message.started"
    static let sessionMessageUpdated = "session.message.updated"
    static let sessionMessageCompleted = "session.message.completed"
    static let sessionTerminalSnapshot = "session.terminal.snapshot"
}

/// JSON fallback used to preserve an unknown command/event payload. Keeping unknown types
/// decodable lets the desktop return `unsupported_command` instead of dropping the socket.
indirect enum RemoteJSONValue: Codable, Equatable, Sendable {
    case object([String: RemoteJSONValue])
    case array([RemoteJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RemoteJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RemoteJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct RemoteEmptyPayload: Codable, Equatable, Sendable {}

enum RemoteAgent: String, Codable, CaseIterable, Equatable, Sendable {
    case claude
    case codex
    case pi
    case shell
    case generic

    init(_ agent: AgentKind) {
        self = RemoteAgent(rawValue: agent.rawValue) ?? .generic
    }

    var localKind: AgentKind {
        AgentKind(rawValue: rawValue) ?? .generic
    }
}

struct RemoteSessionCreateCommand: Codable, Equatable, Sendable {
    var projectRoot: String
    var agent: RemoteAgent
    var initialPrompt: String?

    init(projectRoot: String, agent: RemoteAgent = .claude, initialPrompt: String? = nil) {
        self.projectRoot = projectRoot
        self.agent = agent
        self.initialPrompt = initialPrompt
    }
}

struct RemoteSessionSendMessageCommand: Codable, Equatable, Sendable {
    var session: String
    var text: String
}

enum RemoteDecision: String, Codable, Equatable, Sendable {
    case allowOnce
    case allowAll
    case deny
}

struct RemoteSessionAnswerDecisionCommand: Codable, Equatable, Sendable {
    var session: String
    var decision: RemoteDecision
}

struct RemoteSessionTerminalOpenCommand: Codable, Equatable, Sendable {
    var session: String
    var subscriptionID: String
    var previousRevision: String?

    private enum CodingKeys: String, CodingKey {
        case session, previousRevision
        case subscriptionID = "subscriptionId"
    }
}

struct RemoteSessionTerminalInputCommand: Codable, Equatable, Sendable {
    var session: String
    var subscriptionID: String
    var input: String

    private enum CodingKeys: String, CodingKey {
        case session, input
        case subscriptionID = "subscriptionId"
    }
}

struct RemoteSessionTerminalCloseCommand: Codable, Equatable, Sendable {
    var session: String
    var subscriptionID: String

    private enum CodingKeys: String, CodingKey {
        case session
        case subscriptionID = "subscriptionId"
    }
}

enum RemoteCommand: Equatable, Sendable {
    case sessionList
    case sessionCreate(RemoteSessionCreateCommand)
    case sessionSendMessage(RemoteSessionSendMessageCommand)
    case sessionAnswerDecision(RemoteSessionAnswerDecisionCommand)
    case sessionTerminalOpen(RemoteSessionTerminalOpenCommand)
    case sessionTerminalInput(RemoteSessionTerminalInputCommand)
    case sessionTerminalClose(RemoteSessionTerminalCloseCommand)
    case projectList
    case unsupported(type: String, payload: RemoteJSONValue)

    var type: String {
        switch self {
        case .sessionList: return RemoteCommandType.sessionList
        case .sessionCreate: return RemoteCommandType.sessionCreate
        case .sessionSendMessage: return RemoteCommandType.sessionSendMessage
        case .sessionAnswerDecision: return RemoteCommandType.sessionAnswerDecision
        case .sessionTerminalOpen: return RemoteCommandType.sessionTerminalOpen
        case .sessionTerminalInput: return RemoteCommandType.sessionTerminalInput
        case .sessionTerminalClose: return RemoteCommandType.sessionTerminalClose
        case .projectList: return RemoteCommandType.projectList
        case .unsupported(let type, _): return type
        }
    }
}

/// Mobile-to-desktop envelope. The command discriminator remains at the top level to match the
/// relay protocol and keep payloads independently extensible.
struct RemoteCommandEnvelope: Codable, Equatable, Sendable {
    var version: Int
    var id: String
    var sentAt: Date
    var command: RemoteCommand

    init(
        version: Int = RemoteProtocolVersion.current,
        id: String,
        sentAt: Date,
        command: RemoteCommand
    ) {
        self.version = version
        self.id = id
        self.sentAt = sentAt
        self.command = command
    }

    var type: String { command.type }

    private enum CodingKeys: String, CodingKey {
        case version, id, type, sentAt, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(String.self, forKey: .id)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case RemoteCommandType.sessionList:
            command = .sessionList
        case RemoteCommandType.sessionCreate:
            command = .sessionCreate(try container.decode(RemoteSessionCreateCommand.self, forKey: .payload))
        case RemoteCommandType.sessionSendMessage:
            command = .sessionSendMessage(
                try container.decode(RemoteSessionSendMessageCommand.self, forKey: .payload)
            )
        case RemoteCommandType.sessionAnswerDecision:
            command = .sessionAnswerDecision(
                try container.decode(RemoteSessionAnswerDecisionCommand.self, forKey: .payload)
            )
        case RemoteCommandType.sessionTerminalOpen:
            command = .sessionTerminalOpen(
                try container.decode(RemoteSessionTerminalOpenCommand.self, forKey: .payload)
            )
        case RemoteCommandType.sessionTerminalInput:
            command = .sessionTerminalInput(
                try container.decode(RemoteSessionTerminalInputCommand.self, forKey: .payload)
            )
        case RemoteCommandType.sessionTerminalClose:
            command = .sessionTerminalClose(
                try container.decode(RemoteSessionTerminalCloseCommand.self, forKey: .payload)
            )
        case RemoteCommandType.projectList:
            command = .projectList
        default:
            let payload = try container.decodeIfPresent(RemoteJSONValue.self, forKey: .payload) ?? .object([:])
            command = .unsupported(type: type, payload: payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(sentAt, forKey: .sentAt)
        switch command {
        case .sessionList, .projectList:
            try container.encode(RemoteEmptyPayload(), forKey: .payload)
        case .sessionCreate(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionSendMessage(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionAnswerDecision(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionTerminalOpen(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionTerminalInput(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionTerminalClose(let payload):
            try container.encode(payload, forKey: .payload)
        case .unsupported(_, let payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}

enum RemoteAttentionStatus: String, Codable, Equatable, Sendable {
    case working
    case idle
    case decision
    case input
    case finished
}

struct RemoteAttentionDTO: Codable, Equatable, Sendable {
    var status: RemoteAttentionStatus
    var receivedAt: Date?
    var preview: String?

    init(status: RemoteAttentionStatus, receivedAt: Date? = nil, preview: String? = nil) {
        self.status = status
        self.receivedAt = receivedAt
        self.preview = preview
    }

    init(_ attention: AttentionState) {
        switch attention {
        case .working:
            self.init(status: .working)
        case .idle:
            self.init(status: .idle)
        case .pending(let item):
            let status: RemoteAttentionStatus
            switch item.kind {
            case .decision: status = .decision
            case .input: status = .input
            case .finished: status = .finished
            }
            self.init(
                status: status,
                receivedAt: item.receivedAt,
                preview: RemoteWireLimits.prefix(
                    item.preview,
                    maximumUTF8Bytes: RemoteWireLimits.attentionPreviewBytes
                )
            )
        }
    }
}

struct RemoteSessionDTO: Codable, Equatable, Sendable {
    var name: String
    var displayName: String
    var defaultDisplayName: String
    var agent: RemoteAgent
    var projectRoot: String
    var cwd: String
    var gitBranch: String?
    var attention: RemoteAttentionDTO
    var lastMessage: String?
    var lastActivity: Date
    var isAttached: Bool
    var unacknowledged: Bool
    var launching: Bool
    /// Current in-progress assistant text. This makes a fresh mobile snapshot sufficient to
    /// recover a stream even though ephemeral stream events are not retained by the relay.
    var liveMessage: String?
    var liveMessageTruncated: Bool?

    init(_ session: Session) {
        name = RemoteWireLimits.prefix(session.name, maximumUTF8Bytes: RemoteWireLimits.sessionNameBytes)
        displayName = RemoteWireLimits.prefix(
            session.displayName,
            maximumUTF8Bytes: RemoteWireLimits.displayNameBytes
        )
        defaultDisplayName = RemoteWireLimits.prefix(
            session.defaultDisplayName,
            maximumUTF8Bytes: RemoteWireLimits.displayNameBytes
        )
        agent = RemoteAgent(session.agent)
        projectRoot = RemoteWireLimits.prefix(session.projectRoot, maximumUTF8Bytes: RemoteWireLimits.pathBytes)
        cwd = RemoteWireLimits.prefix(session.cwd, maximumUTF8Bytes: RemoteWireLimits.pathBytes)
        gitBranch = RemoteWireLimits.optionalPrefix(
            session.git?.branch,
            maximumUTF8Bytes: RemoteWireLimits.branchBytes
        )
        attention = RemoteAttentionDTO(session.attention)
        lastMessage = RemoteWireLimits.optionalPrefix(
            session.lastMessage,
            maximumUTF8Bytes: RemoteWireLimits.lastMessageBytes
        )
        lastActivity = session.lastActivity
        isAttached = session.isAttached
        unacknowledged = session.unacknowledged
        launching = session.launching
        liveMessage = RemoteWireLimits.optionalPrefix(
            session.liveTail,
            maximumUTF8Bytes: RemoteWireLimits.streamMessageBytes
        )
        liveMessageTruncated = session.liveTail.map {
            $0.utf8.count > RemoteWireLimits.streamMessageBytes ? true : nil
        } ?? nil
    }

    init(
        name: String,
        displayName: String,
        defaultDisplayName: String,
        agent: RemoteAgent,
        projectRoot: String,
        cwd: String,
        gitBranch: String?,
        attention: RemoteAttentionDTO,
        lastMessage: String?,
        lastActivity: Date,
        isAttached: Bool,
        unacknowledged: Bool,
        launching: Bool,
        liveMessage: String? = nil,
        liveMessageTruncated: Bool? = nil
    ) {
        self.name = RemoteWireLimits.prefix(name, maximumUTF8Bytes: RemoteWireLimits.sessionNameBytes)
        self.displayName = RemoteWireLimits.prefix(
            displayName,
            maximumUTF8Bytes: RemoteWireLimits.displayNameBytes
        )
        self.defaultDisplayName = RemoteWireLimits.prefix(
            defaultDisplayName,
            maximumUTF8Bytes: RemoteWireLimits.displayNameBytes
        )
        self.agent = agent
        self.projectRoot = RemoteWireLimits.prefix(projectRoot, maximumUTF8Bytes: RemoteWireLimits.pathBytes)
        self.cwd = RemoteWireLimits.prefix(cwd, maximumUTF8Bytes: RemoteWireLimits.pathBytes)
        self.gitBranch = RemoteWireLimits.optionalPrefix(
            gitBranch,
            maximumUTF8Bytes: RemoteWireLimits.branchBytes
        )
        self.attention = RemoteAttentionDTO(
            status: attention.status,
            receivedAt: attention.receivedAt,
            preview: RemoteWireLimits.optionalPrefix(
                attention.preview,
                maximumUTF8Bytes: RemoteWireLimits.attentionPreviewBytes
            )
        )
        self.lastMessage = RemoteWireLimits.optionalPrefix(
            lastMessage,
            maximumUTF8Bytes: RemoteWireLimits.lastMessageBytes
        )
        self.lastActivity = lastActivity
        self.isAttached = isAttached
        self.unacknowledged = unacknowledged
        self.launching = launching
        self.liveMessage = RemoteWireLimits.optionalPrefix(
            liveMessage,
            maximumUTF8Bytes: RemoteWireLimits.streamMessageBytes
        )
        self.liveMessageTruncated = liveMessageTruncated == true ? true : nil
    }
}

struct RemoteProjectDTO: Codable, Equatable, Sendable {
    var rootPath: String
    var name: String
    var emoji: String?

    init(_ project: Project) {
        rootPath = RemoteWireLimits.prefix(project.rootPath, maximumUTF8Bytes: RemoteWireLimits.pathBytes)
        name = RemoteWireLimits.prefix(project.name, maximumUTF8Bytes: RemoteWireLimits.projectNameBytes)
        emoji = RemoteWireLimits.optionalPrefix(
            project.emoji,
            maximumUTF8Bytes: RemoteWireLimits.emojiBytes
        )
    }

    init(rootPath: String, name: String, emoji: String? = nil) {
        self.rootPath = RemoteWireLimits.prefix(rootPath, maximumUTF8Bytes: RemoteWireLimits.pathBytes)
        self.name = RemoteWireLimits.prefix(name, maximumUTF8Bytes: RemoteWireLimits.projectNameBytes)
        self.emoji = RemoteWireLimits.optionalPrefix(
            emoji,
            maximumUTF8Bytes: RemoteWireLimits.emojiBytes
        )
    }
}

enum RemoteCapability: String, Codable, CaseIterable, Equatable, Sendable {
    case sessionsRead = "sessions:read"
    case sessionsWrite = "sessions:write"
    case sessionsStream = "sessions:stream"
    case sessionsTerminal = "sessions:terminal"
    case projectsRead = "projects:read"
    case decisionsAnswer = "decisions:answer"
}

struct RemoteSessionSnapshot: Codable, Equatable, Sendable {
    var generatedAt: Date
    var sessions: [RemoteSessionDTO]
    var projects: [RemoteProjectDTO]
    var capabilities: [RemoteCapability]
    /// Present only when the gateway had to reduce a snapshot to stay within the transport
    /// budget. The retained arrays preserve their priority order (needs-you/recent and MRU).
    var truncated: Bool? = nil
    var totalSessionCount: Int? = nil
    var totalProjectCount: Int? = nil
}

struct RemoteAcknowledgement: Codable, Equatable, Sendable {
    var commandType: String
    var resourceID: String?
}

struct RemoteCommandFailure: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var retryable: Bool
}

struct RemoteMessageDelivered: Codable, Equatable, Sendable {
    var session: String
}

struct RemoteSessionTerminalSnapshot: Codable, Equatable, Sendable {
    var session: String
    var subscriptionID: String
    var revision: String
    var content: String?
    var columns: Int
    var rows: Int
    var cursorX: Int
    var cursorY: Int
    var truncated: Bool

    init(
        session: String,
        subscriptionID: String,
        revision: String,
        pane: TerminalPaneSnapshot,
        omitContent: Bool = false
    ) {
        self.session = RemoteWireLimits.prefix(
            session,
            maximumUTF8Bytes: RemoteWireLimits.sessionNameBytes
        )
        self.subscriptionID = subscriptionID
        self.revision = revision
        let truncated = pane.content.utf8.count > RemoteWireLimits.terminalSnapshotBytes
        self.content = omitContent ? nil : RemoteWireLimits.prefix(
            pane.content,
            maximumUTF8Bytes: RemoteWireLimits.terminalSnapshotBytes
        )
        columns = max(1, min(pane.columns, 1_000))
        rows = max(1, min(pane.rows, 1_000))
        cursorX = max(0, min(pane.cursorX, columns - 1))
        cursorY = max(0, min(pane.cursorY, rows - 1))
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case session, revision, content, columns, rows, cursorX, cursorY, truncated
        case subscriptionID = "subscriptionId"
    }
}

/// Self-contained live response state. `text` is the complete bounded response observed at this
/// sequence, rather than a fragile suffix, so a mobile can recover after a dropped frame.
struct RemoteSessionMessageStream: Codable, Equatable, Sendable {
    var session: String
    var messageID: String
    var sequence: Int
    var text: String
    var truncated: Bool

    init(session: String, messageID: String, sequence: Int, text: String, truncated: Bool) {
        self.session = RemoteWireLimits.prefix(
            session,
            maximumUTF8Bytes: RemoteWireLimits.sessionNameBytes
        )
        self.messageID = messageID
        self.sequence = max(0, sequence)
        self.text = RemoteWireLimits.prefix(
            text,
            maximumUTF8Bytes: RemoteWireLimits.streamMessageBytes
        )
        self.truncated = truncated || text.utf8.count > RemoteWireLimits.streamMessageBytes
    }
}

enum RemoteEvent: Equatable, Sendable {
    case acknowledgement(RemoteAcknowledgement)
    case error(RemoteCommandFailure)
    case sessionSnapshot(RemoteSessionSnapshot)
    case messageDelivered(RemoteMessageDelivered)
    case sessionMessageStarted(RemoteSessionMessageStream)
    case sessionMessageUpdated(RemoteSessionMessageStream)
    case sessionMessageCompleted(RemoteSessionMessageStream)
    case sessionTerminalSnapshot(RemoteSessionTerminalSnapshot)
    case unsupported(type: String, payload: RemoteJSONValue)

    var type: String {
        switch self {
        case .acknowledgement: return RemoteEventType.acknowledgement
        case .error: return RemoteEventType.error
        case .sessionSnapshot: return RemoteEventType.sessionSnapshot
        case .messageDelivered: return RemoteEventType.messageDelivered
        case .sessionMessageStarted: return RemoteEventType.sessionMessageStarted
        case .sessionMessageUpdated: return RemoteEventType.sessionMessageUpdated
        case .sessionMessageCompleted: return RemoteEventType.sessionMessageCompleted
        case .sessionTerminalSnapshot: return RemoteEventType.sessionTerminalSnapshot
        case .unsupported(let type, _): return type
        }
    }
}

/// Desktop-to-mobile envelope. `replyTo` correlates command-specific events while unsolicited
/// snapshot publications leave it nil.
struct RemoteEventEnvelope: Codable, Equatable, Sendable {
    var version: Int
    var id: String
    var sentAt: Date
    var replyTo: String?
    var event: RemoteEvent

    init(
        version: Int = RemoteProtocolVersion.current,
        id: String,
        sentAt: Date,
        replyTo: String? = nil,
        event: RemoteEvent
    ) {
        self.version = version
        self.id = id
        self.sentAt = sentAt
        self.replyTo = replyTo
        self.event = event
    }

    var type: String { event.type }

    private enum CodingKeys: String, CodingKey {
        case version, id, type, sentAt, replyTo, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(String.self, forKey: .id)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case RemoteEventType.acknowledgement:
            event = .acknowledgement(try container.decode(RemoteAcknowledgement.self, forKey: .payload))
        case RemoteEventType.error:
            event = .error(try container.decode(RemoteCommandFailure.self, forKey: .payload))
        case RemoteEventType.sessionSnapshot:
            event = .sessionSnapshot(try container.decode(RemoteSessionSnapshot.self, forKey: .payload))
        case RemoteEventType.messageDelivered:
            event = .messageDelivered(try container.decode(RemoteMessageDelivered.self, forKey: .payload))
        case RemoteEventType.sessionMessageStarted:
            event = .sessionMessageStarted(try container.decode(RemoteSessionMessageStream.self, forKey: .payload))
        case RemoteEventType.sessionMessageUpdated:
            event = .sessionMessageUpdated(try container.decode(RemoteSessionMessageStream.self, forKey: .payload))
        case RemoteEventType.sessionMessageCompleted:
            event = .sessionMessageCompleted(try container.decode(RemoteSessionMessageStream.self, forKey: .payload))
        case RemoteEventType.sessionTerminalSnapshot:
            event = .sessionTerminalSnapshot(
                try container.decode(RemoteSessionTerminalSnapshot.self, forKey: .payload)
            )
        default:
            let payload = try container.decodeIfPresent(RemoteJSONValue.self, forKey: .payload) ?? .object([:])
            event = .unsupported(type: type, payload: payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        switch event {
        case .acknowledgement(let payload):
            try container.encode(payload, forKey: .payload)
        case .error(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionSnapshot(let payload):
            try container.encode(payload, forKey: .payload)
        case .messageDelivered(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionMessageStarted(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionMessageUpdated(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionMessageCompleted(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionTerminalSnapshot(let payload):
            try container.encode(payload, forKey: .payload)
        case .unsupported(_, let payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}

enum RemoteWireCodec {
    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondsDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func encode(_ command: RemoteCommandEnvelope) throws -> Data {
        try encoder().encode(command)
    }

    static func encode(_ event: RemoteEventEnvelope) throws -> Data {
        try encoder().encode(event)
    }

    /// Fit full snapshots under the control-plane budget. Normal ack/error events are already
    /// tightly bounded; a non-snapshot overage is rejected instead of silently altered.
    static func encodeForTransport(
        _ event: RemoteEventEnvelope,
        maximumBytes: Int = RemoteWireLimits.maximumOutboundFrameBytes
    ) throws -> Data {
        var candidate = event
        if case .sessionSnapshot(var snapshot) = candidate.event {
            let sessionCount = snapshot.sessions.count
            let projectCount = snapshot.projects.count
            if sessionCount > RemoteWireLimits.maximumSnapshotItems {
                snapshot.sessions = Array(snapshot.sessions.prefix(RemoteWireLimits.maximumSnapshotItems))
            }
            if projectCount > RemoteWireLimits.maximumSnapshotItems {
                snapshot.projects = Array(snapshot.projects.prefix(RemoteWireLimits.maximumSnapshotItems))
            }
            if snapshot.sessions.count != sessionCount || snapshot.projects.count != projectCount {
                snapshot.truncated = true
                if snapshot.totalSessionCount == nil { snapshot.totalSessionCount = sessionCount }
                if snapshot.totalProjectCount == nil { snapshot.totalProjectCount = projectCount }
                candidate.event = .sessionSnapshot(snapshot)
            }
        }

        var data = try encode(candidate)
        guard data.count > maximumBytes else { return data }
        guard case .sessionSnapshot(var snapshot) = candidate.event else {
            throw RemoteWireCodecError.outboundFrameTooLarge
        }

        if snapshot.totalSessionCount == nil { snapshot.totalSessionCount = snapshot.sessions.count }
        if snapshot.totalProjectCount == nil { snapshot.totalProjectCount = snapshot.projects.count }
        snapshot.truncated = true

        while data.count > maximumBytes,
              !snapshot.sessions.isEmpty || !snapshot.projects.isEmpty {
            let sessionBytes = try snapshot.sessions.last.map { try encoder().encode($0).count } ?? -1
            let projectBytes = try snapshot.projects.last.map { try encoder().encode($0).count } ?? -1
            if sessionBytes >= projectBytes, !snapshot.sessions.isEmpty {
                snapshot.sessions.removeLast()
            } else if !snapshot.projects.isEmpty {
                snapshot.projects.removeLast()
            }
            candidate.event = .sessionSnapshot(snapshot)
            data = try encode(candidate)
        }

        guard data.count <= maximumBytes else {
            throw RemoteWireCodecError.outboundFrameTooLarge
        }
        return data
    }

    static func decodeCommand(from data: Data) throws -> RemoteCommandEnvelope {
        try decoder().decode(RemoteCommandEnvelope.self, from: data)
    }

    static func decodeEvent(from data: Data) throws -> RemoteEventEnvelope {
        try decoder().decode(RemoteEventEnvelope.self, from: data)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalDateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            if let date = fractionalDateFormatter.date(from: raw) { return date }
            if let date = wholeSecondsDateFormatter.date(from: raw) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 timestamp."
            )
        }
        return decoder
    }
}

enum RemoteWireCodecError: Error, Equatable {
    case outboundFrameTooLarge
}
