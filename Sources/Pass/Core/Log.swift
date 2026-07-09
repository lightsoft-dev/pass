import Foundation
import OSLog

/// Central logging. Stream with: `log stream --predicate 'subsystem == "dev.lightsoft.pass"'`
enum Log {
    static let subsystem = "dev.lightsoft.pass"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tmux = Logger(subsystem: subsystem, category: "tmux")
    static let hooks = Logger(subsystem: subsystem, category: "hooks")
    static let inbox = Logger(subsystem: subsystem, category: "inbox")
    static let inject = Logger(subsystem: subsystem, category: "inject")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
