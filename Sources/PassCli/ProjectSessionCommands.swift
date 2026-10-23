import ArgumentParser
import Foundation

/// Project-scoped worker control for the permanent Pi coordinator.
struct ProjectSessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage worker sessions in this project (from its project agent).",
        subcommands: [List.self, Start.self, Send.self, Choose.self, Tail.self, Remove.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List this project's worker sessions.")

        @OptionGroup var source: SessionOption
        @Flag(help: "Machine-readable output.") var json = false

        func run() async throws {
            let result = await PassClient.post("/cli/session/list",
                CLIProjectSessionRequest(sourceSession: source.resolved()),
                as: CLIProjectSessionListResponse.self)
            guard result.ok else { PassClient.fail(result.error ?? "session list failed", code: PassExit.refused) }
            if json { printJSON(result); return }
            if result.sessions.isEmpty { print("No worker sessions in \(result.projectRoot ?? "project")"); return }
            for session in result.sessions {
                print("\(session.name)\t\(session.agent)\t\(session.state)\t\(session.lastActivitySecondsAgo)s since activity\t\(session.cwd)")
            }
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a worker in this project.")

        @OptionGroup var source: SessionOption
        @Option(help: "Agent: claude, codex, grok, or pi.") var agent = "claude"
        @Option(help: "Task to give the new worker immediately.") var message = ""
        @Flag(help: "Machine-readable output.") var json = false

        func run() async throws {
            let result = await PassClient.post("/cli/session/start",
                CLIProjectSessionStartRequest(sourceSession: source.resolved(),
                                              agent: agent, message: message),
                as: CLIProjectSessionResponse.self)
            guard result.ok else { PassClient.fail(result.error ?? "session start failed", code: PassExit.refused) }
            if json { printJSON(result) } else { print("started \(result.session ?? "worker")") }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send a task to an existing worker.")

        @OptionGroup var source: SessionOption
        @Argument(help: "Worker session name.") var target: String
        @Argument(help: "Message for the worker.") var message: String
        @Flag(help: "Machine-readable output.") var json = false

        func run() async throws {
            let result = await PassClient.post("/cli/session/send",
                CLIProjectSessionSendRequest(sourceSession: source.resolved(),
                                             targetSession: target, message: message),
                as: CLIProjectSessionResponse.self)
            guard result.ok else { PassClient.fail(result.error ?? "session send failed", code: PassExit.refused) }
            if json { printJSON(result) } else { print("sent to \(result.session ?? target)") }
        }
    }

    struct Tail: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read a worker's recent terminal output.")

        @OptionGroup var source: SessionOption
        @Argument(help: "Worker session name.") var target: String
        @Option(help: "Recent lines, 1 to 200.") var lines = 80
        @Flag(help: "Machine-readable output.") var json = false

        func run() async throws {
            let result = await PassClient.post("/cli/session/tail",
                CLIProjectSessionTailRequest(sourceSession: source.resolved(),
                                             targetSession: target, lines: lines),
                as: CLIProjectSessionResponse.self)
            guard result.ok else { PassClient.fail(result.error ?? "session tail failed", code: PassExit.refused) }
            if json { printJSON(result) } else { print(result.content ?? "", terminator: "") }
        }
    }

    struct Choose: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Choose a visible numbered worker option after the user selects it.")

        @OptionGroup var source: SessionOption
        @Argument(help: "Worker session name.") var target: String
        @Argument(help: "Visible option number, 1 to 20.") var option: Int
        @Flag(help: "Machine-readable output.") var json = false

        func run() async throws {
            let result = await PassClient.post("/cli/session/choose",
                CLIProjectSessionChooseRequest(sourceSession: source.resolved(),
                                               targetSession: target, option: option),
                as: CLIProjectSessionResponse.self)
            guard result.ok else { PassClient.fail(result.error ?? "session choose failed", code: PassExit.refused) }
            if json { printJSON(result) } else { print("chose \(option) in \(result.session ?? target)") }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a worker session in this project.")

        @OptionGroup var source: SessionOption
        @Argument(help: "Worker session name.") var target: String
        @Flag(help: "Machine-readable output.") var json = false

        func run() async throws {
            let result = await PassClient.post("/cli/session/remove",
                CLIProjectSessionRemoveRequest(sourceSession: source.resolved(),
                                               targetSession: target),
                as: CLIProjectSessionResponse.self)
            guard result.ok else { PassClient.fail(result.error ?? "session remove failed", code: PassExit.refused) }
            if json { printJSON(result) } else { print("removed \(result.session ?? target)") }
        }
    }
}

private func printJSON<T: Encodable>(_ value: T) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    print(String(decoding: data, as: UTF8.self))
}
