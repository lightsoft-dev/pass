import ArgumentParser
import Foundation

struct Browser: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The embedded browser pane beside a session's terminal.",
        subcommands: [Open.self, Close.self, Tabs.self, Screenshot.self, Read.self]
    )
}

extension Browser {
    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a URL beside this session's terminal.",
            discussion: """
            URL forms: http(s)://…, localhost:5173, :5173, 5173, foo.com/bar, or a local \
            file (./dist/index.html). The page appears in a split next to the session's \
            terminal; repeated opens reuse the same pane. If the pass panel is hidden it \
            surfaces quietly (the user's editor keeps focus).
            """)

        @Argument(help: "The URL (or local file) to show.")
        var url: String

        @OptionGroup var target: SessionOption

        @Flag(help: "Load without surfacing the panel — the session row just gets a 🌐 badge.")
        var background = false

        @Flag(help: "Machine-readable output.")
        var json = false

        func run() async throws {
            let session = target.resolved()
            let response = await PassClient.post(
                "/cli/browser/open",
                CLIOpenRequest(session: session, url: absolutized(url),
                               background: background ? true : nil),
                as: CLIOpenResponse.self)
            if json { PassClient.printJSON(response) }
            guard response.ok else {
                PassClient.fail("open failed: \(response.error ?? "unknown error")",
                                code: PassExit.refused)
            }
            if !json { print("opened \(response.resolvedURL ?? url) · session \(session)") }
        }

        /// Relative file paths that exist become absolute so the app (different cwd)
        /// resolves the same file the agent meant.
        private func absolutized(_ raw: String) -> String {
            let expanded = NSString(string: raw).expandingTildeInPath
            if expanded.hasPrefix("/") { return expanded }
            guard raw.hasPrefix("./") || raw.hasPrefix("../") || looksLikeExistingFile(raw) else {
                return raw
            }
            let cwd = FileManager.default.currentDirectoryPath
            return NSString(string: NSString(string: cwd).appendingPathComponent(expanded))
                .standardizingPath
        }

        private func looksLikeExistingFile(_ raw: String) -> Bool {
            guard !raw.contains("://") else { return false }
            let cwd = FileManager.default.currentDirectoryPath
            return FileManager.default.fileExists(
                atPath: NSString(string: cwd).appendingPathComponent(raw))
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close this session's browser pane.")

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func run() async throws {
            let session = target.resolved()
            let response = await PassClient.post(
                "/cli/browser/close", CLICloseRequest(session: session),
                as: CLISimpleResponse.self)
            if json { PassClient.printJSON(response) }
            guard response.ok else {
                PassClient.fail("close failed: \(response.error ?? "unknown error")",
                                code: PassExit.refused)
            }
            if !json { print("closed · session \(session)") }
        }
    }

    struct Tabs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List open pages across all sessions.")

        @Flag(help: "Machine-readable output.")
        var json = false

        func run() async throws {
            let response = await PassClient.get("/cli/browser/tabs", as: CLITabsResponse.self)
            if json {
                PassClient.printJSON(response)
                return
            }
            guard !response.tabs.isEmpty else {
                print("no open pages")
                return
            }
            for tab in response.tabs {
                let title = tab.title.map { " · \($0)" } ?? ""
                let unseen = tab.unseen ? " (unseen)" : ""
                print("\(tab.session)\t\(tab.url)\(title)\(unseen)")
            }
        }
    }

    struct Screenshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Capture the open page as a PNG; prints the file's path.",
            discussion: """
            Captures what the user sees (viewport). If the pass panel is hidden it surfaces \
            first so the page actually renders. Read the produced file to inspect your UI work.
            """)

        @Option(name: [.customShort("o"), .customLong("out")],
                help: "Output PNG path (default: ~/.pass/screenshots/<session>-<time>.png).")
        var out: String?

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func run() async throws {
            let session = target.resolved()
            let response = await PassClient.post(
                "/cli/browser/screenshot",
                CLIScreenshotRequest(session: session, path: out.map(absolutized)),
                as: CLIScreenshotResponse.self)
            if json { PassClient.printJSON(response) }
            guard response.ok, let path = response.path else {
                PassClient.fail("screenshot failed: \(response.error ?? "unknown error")",
                                code: PassExit.refused)
            }
            if !json { print(path) } // bare path → composable: open "$(passcli browser screenshot)"
        }

        private func absolutized(_ raw: String) -> String {
            let expanded = NSString(string: raw).expandingTildeInPath
            if expanded.hasPrefix("/") { return expanded }
            let cwd = FileManager.default.currentDirectoryPath
            return NSString(string: NSString(string: cwd).appendingPathComponent(expanded))
                .standardizingPath
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the open page's content (text by default).")

        @Option(help: "\"text\" (innerText, default) or \"html\" (outerHTML).")
        var format: String = "text"

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func validate() throws {
            guard ["text", "html"].contains(format.lowercased()) else {
                throw ValidationError("format must be \"text\" or \"html\"")
            }
        }

        func run() async throws {
            let session = target.resolved()
            let response = await PassClient.post(
                "/cli/browser/read",
                CLIReadRequest(session: session, format: format.lowercased()),
                as: CLIReadResponse.self)
            if json { PassClient.printJSON(response); return }
            guard response.ok, let content = response.content else {
                PassClient.fail("read failed: \(response.error ?? "unknown error")",
                                code: PassExit.refused)
            }
            print(content)
            if response.truncated == true {
                FileHandle.standardError.write(Data("(truncated at 512KB)\n".utf8))
            }
        }
    }
}
