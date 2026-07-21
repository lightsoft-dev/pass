import ArgumentParser
import Foundation

/// `passcli` — the agent-facing control plane for the pass app (BROWSER.md Part B).
/// Ships inside Pass.app; sessions reach it via the stable symlink in `$PASS_CLI`
/// (~/.pass/bin/passcli). `--help` is the agent's documentation — keep it sharp.
@main
struct PassCli: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "passcli",
        abstract: "Control the pass app from a session — show pages in its embedded browser, beside your terminal.",
        discussion: """
        Runs inside a pass tmux session ($PASS_SESSION identifies you) or anywhere with \
        --session. Talks to the pass app's loopback server (127.0.0.1:49817; override with \
        $PASS_PORT), so the app must be running.
        """,
        version: "0.1.0",
        subcommands: [Browser.self, Config.self, ExtensionCommand.self, Status.self, Advertise.self]
    )
}

/// Shared `--session` option + the resolution ladder (BROWSER.md §5.3).
struct SessionOption: ParsableArguments {
    @Option(help: "Target pass session (default: $PASS_SESSION, then the enclosing tmux session).")
    var session: String?

    func resolved() -> String {
        guard let name = PassClient.resolveSession(explicit: session) else {
            PassClient.fail(
                "no target session — pass --session <name>, or run inside a pass tmux session",
                code: PassExit.usage)
        }
        return name
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Is pass running?")

    @Flag(help: "Machine-readable output.")
    var json = false

    func run() async throws {
        let up = await PassClient.healthy()
        if json {
            print(#"{"running":\#(up),"port":\#(PassClient.port)}"#)
        } else if up {
            print("pass is running on 127.0.0.1:\(PassClient.port)")
        } else {
            FileHandle.standardError.write(
                Data("pass is not running (127.0.0.1:\(PassClient.port))\n".utf8))
        }
        if !up { throw ExitCode(PassExit.notRunning) }
    }
}

/// SessionStart hook payload (installed by pass into ~/.claude/settings.json): one paragraph
/// of additionalContext teaching the agent that the embedded browser exists. Prints NOTHING
/// unless this is a pass session AND pass is running — zero noise in every other session.
struct Advertise: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "SessionStart hook payload (silent outside pass sessions).",
        shouldDisplay: false
    )

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let session = env["PASS_SESSION"], !session.isEmpty else { return }
        guard await PassClient.healthy() else { return }
        let cli = env["PASS_CLI"] ?? "passcli"
        let context = """
        pass (the session manager running this terminal) shows an embedded browser pane \
        beside this session's terminal. Use it to SHOW the user things and to VERIFY your \
        own UI work:
        - "\(cli)" browser open <url> — open a page next to this terminal (your dev server, \
        a PR page, or a local file like ./dist/index.html)
        - "\(cli)" browser screenshot -o <path>.png — capture what the user currently sees, \
        then read that file to check your frontend work
        - "\(cli)" browser read — the open page as plain text
        - "\(cli)" config url add <url> --label <name> — save a project URL into \
        pass-config.json so it appears in the session URL bar
        It shows pages to the human — it is NOT a browser-automation tool (no clicking, no JS).
        """
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "SessionStart",
                "additionalContext": context,
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        print(String(decoding: data, as: UTF8.self))
    }
}
