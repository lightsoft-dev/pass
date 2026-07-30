import ArgumentParser
import Foundation

struct Browser: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open, inspect, and interact with the browser beside a session's terminal.",
        subcommands: [
            Open.self, Close.self, Tabs.self, Snapshot.self,
            Click.self, Fill.self, TypeText.self, Select.self, Press.self, Scroll.self,
            Screenshot.self, Read.self,
        ]
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

    struct Snapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List interactive elements and stable refs for browser actions.",
            discussion: """
            Start each interaction loop here. Actions can optionally require the returned \
            revision, which prevents a stale ref from acting on a changed page.
            """)

        @Flag(help: "Include interactive elements outside the current viewport.")
        var all = false

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func run() async throws {
            let response = await PassClient.post(
                "/cli/browser/snapshot",
                CLIBrowserSnapshotRequest(
                    session: target.resolved(),
                    all: all ? true : nil),
                as: CLIBrowserSnapshotResponse.self)
            if json { PassClient.printJSON(response) }
            guard response.ok else {
                PassClient.fail("snapshot failed: \(response.error ?? "unknown error")",
                                code: PassExit.refused)
            }
            if !json { BrowserCommandSupport.printSnapshot(response) }
        }
    }

    struct Click: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Click an element from the latest snapshot.")

        @Argument(help: "Element ref from `browser snapshot` (for example @e1).")
        var ref: String

        @Option(help: "Require this snapshot revision before acting.")
        var revision: Int?

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func validate() throws {
            try BrowserCommandSupport.validateRef(ref)
            try BrowserCommandSupport.validateRevision(revision)
        }

        func run() async throws {
            await BrowserCommandSupport.performAction(
                CLIBrowserActionRequest(
                    session: target.resolved(), action: "click",
                    ref: ref, revision: revision),
                json: json)
        }
    }

    struct Fill: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace an editable element's value.")

        @Argument(help: "Element ref from `browser snapshot` (for example @e1).")
        var ref: String

        @Argument(help: "Replacement text (never echoed in human-readable output).")
        var text: String

        @Option(help: "Require this snapshot revision before acting.")
        var revision: Int?

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func validate() throws {
            try BrowserCommandSupport.validateRef(ref)
            try BrowserCommandSupport.validateRevision(revision)
        }

        func run() async throws {
            await BrowserCommandSupport.performAction(
                CLIBrowserActionRequest(
                    session: target.resolved(), action: "fill",
                    ref: ref, text: text, revision: revision),
                json: json)
        }
    }

    struct TypeText: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type text into an editable element without clearing it first.")

        @Argument(help: "Element ref from `browser snapshot` (for example @e1).")
        var ref: String

        @Argument(help: "Text to type (never echoed in human-readable output).")
        var text: String

        @Option(help: "Require this snapshot revision before acting.")
        var revision: Int?

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func validate() throws {
            try BrowserCommandSupport.validateRef(ref)
            try BrowserCommandSupport.validateRevision(revision)
        }

        func run() async throws {
            await BrowserCommandSupport.performAction(
                CLIBrowserActionRequest(
                    session: target.resolved(), action: "type",
                    ref: ref, text: text, revision: revision),
                json: json)
        }
    }

    struct Select: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Select an option by value.")

        @Argument(help: "Element ref from `browser snapshot` (for example @e1).")
        var ref: String

        @Argument(help: "Option value (never echoed in human-readable output).")
        var value: String

        @Option(help: "Require this snapshot revision before acting.")
        var revision: Int?

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func validate() throws {
            try BrowserCommandSupport.validateRef(ref)
            try BrowserCommandSupport.validateRevision(revision)
        }

        func run() async throws {
            await BrowserCommandSupport.performAction(
                CLIBrowserActionRequest(
                    session: target.resolved(), action: "select",
                    ref: ref, text: value, revision: revision),
                json: json)
        }
    }

    struct Press: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Press a key on an element, or on the focused page.")

        @Argument(help: "Supported key: Enter, Space, Tab, Escape, or one text character.")
        var key: String

        @Option(help: "Element ref to receive the key (default: focused element or page).")
        var ref: String?

        @Option(help: "Require this snapshot revision before acting.")
        var revision: Int?

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func validate() throws {
            guard !key.isEmpty else {
                throw ValidationError("key must not be empty")
            }
            if let ref { try BrowserCommandSupport.validateRef(ref) }
            try BrowserCommandSupport.validateRevision(revision)
        }

        func run() async throws {
            await BrowserCommandSupport.performAction(
                CLIBrowserActionRequest(
                    session: target.resolved(), action: "press",
                    ref: ref, key: key, revision: revision),
                json: json)
        }
    }

    struct Scroll: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Scroll the page in one direction.")

        @Argument(help: "Direction: up, down, left, or right.")
        var direction: BrowserScrollDirection

        @Argument(help: "Distance in CSS pixels (default: 600).")
        var amount: Double = 600

        @Option(help: "Require this snapshot revision before acting.")
        var revision: Int?

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func validate() throws {
            try BrowserCommandSupport.validateAmount(amount)
            try BrowserCommandSupport.validateRevision(revision)
        }

        func run() async throws {
            await BrowserCommandSupport.performAction(
                CLIBrowserActionRequest(
                    session: target.resolved(), action: "scroll",
                    direction: direction.rawValue, amount: amount, revision: revision),
                json: json)
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

enum BrowserScrollDirection: String, ExpressibleByArgument, CaseIterable {
    case up
    case down
    case left
    case right
}

private enum BrowserCommandSupport {
    static func validateRef(_ ref: String) throws {
        let bytes = Array(ref.utf8)
        guard bytes.count >= 3,
              bytes[0] == 0x40,
              bytes[1] == 0x65,
              (49...57).contains(bytes[2]),
              bytes.dropFirst(3).allSatisfy({ (48...57).contains($0) }) else {
            throw ValidationError(
                "ref must match @e<number> (for example @e1); run `browser snapshot` for refs")
        }
    }

    static func validateRevision(_ revision: Int?) throws {
        if let revision, revision <= 0 {
            throw ValidationError("revision must be a positive integer")
        }
    }

    static func validateAmount(_ amount: Double) throws {
        guard amount.isFinite, (1...10_000).contains(amount) else {
            throw ValidationError("amount must be between 1 and 10000")
        }
    }

    static func performAction(_ request: CLIBrowserActionRequest, json: Bool) async {
        let response = await PassClient.post(
            "/cli/browser/action", request, as: CLIBrowserActionResponse.self)
        if json { PassClient.printJSON(response) }
        guard response.ok else {
            PassClient.fail(
                "\(request.action) failed: \(response.error ?? "unknown error")",
                code: PassExit.refused)
        }
        guard !json else { return }

        var fields = [
            "ok",
            "action=\(response.action ?? request.action)",
        ]
        if let ref = response.ref ?? request.ref {
            fields.append("ref=\(ref)")
        }
        if let url = response.url {
            fields.append("url=\(quoted(url))")
        }
        if let revision = response.revision {
            fields.append("revision=\(revision)")
        }
        fields.append(response.snapshotRecommended == true
                      ? "resnapshot=recommended"
                      : "resnapshot=optional")
        print(fields.joined(separator: " "))
    }

    static func printSnapshot(_ response: CLIBrowserSnapshotResponse) {
        var fields = [
            "url=\(quoted(response.url ?? ""))",
            "title=\(quoted(response.title ?? ""))",
            "revision=\(response.revision.map(String.init) ?? "-")",
        ]
        if let viewport = response.viewport {
            fields.append(
                "viewport={x:\(number(viewport.x)),y:\(number(viewport.y))," +
                "width:\(number(viewport.width)),height:\(number(viewport.height))," +
                "documentWidth:\(number(viewport.documentWidth))," +
                "documentHeight:\(number(viewport.documentHeight))}")
        } else {
            fields.append("viewport=-")
        }
        if response.truncated == true {
            fields.append("truncated=true")
        }
        print(fields.joined(separator: " "))

        for element in response.elements {
            var details = [
                "\(element.ref) role=\(quoted(element.role)) name=\(quoted(element.name))",
                "tag=\(quoted(element.tag))",
            ]
            if let type = element.type {
                details.append("type=\(quoted(type))")
            }
            let sensitive = element.sensitive == true ||
                element.type?.lowercased() == "password"
            if !sensitive, let value = element.value {
                details.append("value=\(quoted(value))")
            }
            if let disabled = element.disabled {
                details.append("disabled=\(disabled)")
            }
            if let checked = element.checked {
                details.append("checked=\(checked)")
            }
            if let selected = element.selected {
                details.append("selected=\(selected)")
            }
            if let expanded = element.expanded {
                details.append("expanded=\(expanded)")
            }
            if sensitive {
                details.append("sensitive=true")
            }
            print(details.joined(separator: " "))
        }
    }

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func number(_ value: Double) -> String {
        if value == 0 { return "0" }
        let rounded = value.rounded()
        if rounded == value,
           rounded >= Double(Int64.min),
           rounded <= Double(Int64.max) {
            return String(Int64(rounded))
        }
        return String(value)
    }
}
