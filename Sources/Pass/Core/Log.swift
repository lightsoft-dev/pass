import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Central logging. Stream with: `log stream --predicate 'subsystem == "dev.lightsoft.pass"'`
enum Log {
    static let subsystem = "dev.lightsoft.pass"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tmux = Logger(subsystem: subsystem, category: "tmux")
    static let hooks = Logger(subsystem: subsystem, category: "hooks")
    static let inbox = Logger(subsystem: subsystem, category: "inbox")
    static let inject = Logger(subsystem: subsystem, category: "inject")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let ext = Logger(subsystem: subsystem, category: "extensions")
}

#if !canImport(OSLog)
/// OSLog-shaped shim for Linux: same call-site surface (`Log.tmux.info("… \(x, privacy: .public)")`),
/// output to stderr. Swap the `emit` body for swift-log/journald if structured logging is wanted.
struct Logger: Sendable {
    let subsystem: String
    let category: String

    init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    func debug(_ message: LogMessage) { emit("debug", message) }
    func info(_ message: LogMessage) { emit("info", message) }
    func notice(_ message: LogMessage) { emit("notice", message) }
    func warning(_ message: LogMessage) { emit("warning", message) }
    func error(_ message: LogMessage) { emit("error", message) }
    func fault(_ message: LogMessage) { emit("fault", message) }
    func log(_ message: LogMessage) { emit("log", message) }

    private func emit(_ level: String, _ message: LogMessage) {
        FileHandle.standardError.write(Data("[\(category)] \(level): \(message.rendered)\n".utf8))
    }
}

/// Accepts OSLog's `\(value, privacy: …)` interpolations (privacy is ignored — stderr only).
struct LogPrivacy: Sendable {
    static let `public` = LogPrivacy()
    static let `private` = LogPrivacy()
    static let auto = LogPrivacy()
    static let sensitive = LogPrivacy()
}

struct LogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let rendered: String

    init(stringLiteral value: String) { rendered = value }
    init(stringInterpolation: StringInterpolation) { rendered = stringInterpolation.output }

    struct StringInterpolation: StringInterpolationProtocol {
        var output = ""
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { output += literal }
        mutating func appendInterpolation<T>(_ value: @autoclosure () -> T) {
            output += String(describing: value())
        }
        mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: LogPrivacy) {
            output += String(describing: value())
        }
    }
}
#endif
