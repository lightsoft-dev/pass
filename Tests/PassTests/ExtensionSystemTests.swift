import XCTest
@testable import Pass

final class ExtensionManifestTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-manifest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("slack-notify", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func decode(_ json: String) throws -> ExtensionManifest {
        try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    }

    /// The full v1 shape from docs/EXTENSIONS.md §5 — including the `if` key mapping to
    /// `filter`, and unknown future keys (agents) being ignored rather than fatal.
    func testDecodesFullManifest() throws {
        let m = try decode("""
        {
          "apiVersion": 1,
          "id": "slack-notify",
          "name": "Slack Notify",
          "version": "0.1.0",
          "description": "세션이 입력을 기다리면 Slack으로 알림",
          "permissions": ["events:attention", "run:script"],
          "contributes": {
            "rules": [
              { "on": "attention.pending",
                "if": { "kind": ["decision", "input"] },
                "run": { "script": "notify.sh", "args": ["${session.displayName}"], "timeoutSeconds": 10 } }
            ],
            "commands": [
              { "id": "deploy", "title": "배포 지시", "context": "session",
                "run": { "sendText": "스테이징 배포해줘" } }
            ],
            "agents": [ { "id": "aider", "glyph": "◆" } ]
          }
        }
        """)
        XCTAssertEqual(m.id, "slack-notify")
        XCTAssertEqual(m.contributes?.rules?.first?.filter?.kind, ["decision", "input"])
        XCTAssertEqual(m.contributes?.rules?.first?.run.script, "notify.sh")
        XCTAssertEqual(m.contributes?.commands?.first?.contextKind, "session")
    }

    func testRuleMatching() throws {
        let rule = try JSONDecoder().decode(ExtensionManifest.Rule.self, from: Data("""
        { "on": "attention.pending", "if": { "kind": ["decision"] }, "run": { "notify": { "title": "t" } } }
        """.utf8))
        XCTAssertTrue(rule.matches(event: "attention.pending", kind: "decision"))
        XCTAssertFalse(rule.matches(event: "attention.pending", kind: "input"))
        XCTAssertFalse(rule.matches(event: "attention.pending", kind: nil)) // filtered event needs a kind
        XCTAssertFalse(rule.matches(event: "attention.resolved", kind: "decision"))

        let unfiltered = try JSONDecoder().decode(ExtensionManifest.Rule.self, from: Data("""
        { "on": "session.created", "run": { "notify": { "title": "t" } } }
        """.utf8))
        XCTAssertTrue(unfiltered.matches(event: "session.created", kind: nil))
    }

    func testActionRequiredPermissions() {
        var a = ExtensionManifest.Action()
        a.script = "x.sh"
        XCTAssertEqual(a.requiredPermissions, ["run:script"])
        a.terminal = true
        XCTAssertEqual(a.requiredPermissions, ["run:script", "session:create"])
        var b = ExtensionManifest.Action()
        b.sendText = "hello"
        XCTAssertEqual(b.requiredPermissions, ["session:send"])
        var c = ExtensionManifest.Action()
        c.openWindow = "dashboard"
        XCTAssertEqual(c.requiredPermissions, ["ui:window"])
    }

    func testTemplateExpansion() {
        let ctx = ["session.name": "pass-x", "attention.kind": "decision"]
        XCTAssertEqual(ExtensionTemplate.expand("hi ${session.name}!", context: ctx), "hi pass-x!")
        XCTAssertEqual(ExtensionTemplate.expand("${a}${session.name}", context: ctx), "pass-x") // unknown → ""
        XCTAssertEqual(ExtensionTemplate.expand("no vars", context: ctx), "no vars")
        XCTAssertEqual(ExtensionTemplate.expand("broken ${tail", context: ctx), "broken ${tail")
    }

    func testValidManifestHasNoProblems() throws {
        try Data("#!/bin/bash\n".utf8).write(to: dir.appendingPathComponent("notify.sh"))
        let m = try decode("""
        { "apiVersion": 1, "id": "slack-notify", "name": "n",
          "permissions": ["events:attention", "run:script"],
          "contributes": { "rules": [
            { "on": "attention.pending", "run": { "script": "notify.sh" } } ] } }
        """)
        XCTAssertEqual(m.problems(directory: dir), [])
    }

    func testValidationCatchesEveryProblemClass() throws {
        let m = try decode("""
        { "apiVersion": 3, "id": "Slack_Notify", "name": "n",
          "permissions": ["events:attention", "made-up"],
          "contributes": {
            "commands": [
              { "id": "deploy", "title": "t", "context": "workspace",
                "run": { "sendText": "x", "script": "gone.sh" } },
              { "id": "notes", "title": "t", "run": { "sendText": "x" } }
            ],
            "rules": [
              { "on": "attention.pending", "run": { "script": "/etc/evil.sh" } },
              { "on": "session.created", "run": { "openURL": "https://x" } },
              { "on": "nope.event", "run": { "notify": { "title": "t" } } }
            ] } }
        """)
        let problems = m.problems(directory: dir)
        func has(_ fragment: String) {
            XCTAssertTrue(problems.contains { $0.contains(fragment) },
                          "missing \"\(fragment)\" in \(problems)")
        }
        has("apiVersion 3")                                  // unsupported version
        has("must be lowercase")                             // bad id charset
        has("must match its folder name")                    // id ≠ folder
        has("unknown permission \"made-up\"")
        has("unknown context \"workspace\"")
        has("exactly one of")                                // two effects in one action
        has("sendText needs context \"session\"")            // /notes has no session context
        has("permission \"session:send\" not declared")
        has("relative path inside the extension folder")     // absolute script path
        has("permission \"run:script\" not declared")
        has("permission \"events:session\" not declared")    // session.created without perm
        has("permission \"open:url\" not declared")
        has("unknown event")                                 // nope.event
    }

    func testMissingScriptIsAProblem() throws {
        let m = try decode("""
        { "apiVersion": 1, "id": "slack-notify", "name": "n",
          "permissions": ["run:script"],
          "contributes": { "commands": [
            { "id": "x", "title": "t", "run": { "script": "absent.sh" } } ] } }
        """)
        XCTAssertTrue(m.problems(directory: dir).contains { $0.contains("script not found: absent.sh") })
    }

    /// The containment rule is path-normalizing, not substring-matching: '..' inside a file
    /// NAME is legal; '..' as a path COMPONENT that escapes the folder is not.
    func testScriptContainment() throws {
        try Data("#!/bin/bash\n".utf8).write(to: dir.appendingPathComponent("report..v2.sh"))
        var named = ExtensionManifest.Action(); named.script = "report..v2.sh"
        if case .failure(let m) = named.resolveScript(in: dir) { XCTFail(m.message) }

        var escape = ExtensionManifest.Action(); escape.script = "../../etc/evil.sh"
        guard case .failure(let msg) = escape.resolveScript(in: dir) else {
            return XCTFail("traversal escaped the extension folder")
        }
        XCTAssertTrue(msg.message.contains("stay inside"))

        var absolute = ExtensionManifest.Action(); absolute.script = "/bin/ls"
        guard case .failure = absolute.resolveScript(in: dir) else {
            return XCTFail("absolute path accepted")
        }

        let outside = dir.deletingLastPathComponent().appendingPathComponent("outside.sh")
        try Data("#!/bin/bash\n".utf8).write(to: outside)
        let link = dir.appendingPathComponent("linked.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var symlink = ExtensionManifest.Action(); symlink.script = "linked.sh"
        guard case .failure(let symlinkError) = symlink.resolveScript(in: dir) else {
            return XCTFail("symlink escaped the extension folder")
        }
        XCTAssertTrue(symlinkError.message.contains("stay inside"))
    }

    func testIdentifierRules() {
        XCTAssertTrue(ExtensionManifest.isValidIdentifier("agent-usage"))
        XCTAssertTrue(ExtensionManifest.isValidIdentifier("a2"))
        XCTAssertFalse(ExtensionManifest.isValidIdentifier("-lead"))
        XCTAssertFalse(ExtensionManifest.isValidIdentifier("Upper"))
        XCTAssertFalse(ExtensionManifest.isValidIdentifier("dot.id"))
        XCTAssertFalse(ExtensionManifest.isValidIdentifier(""))
    }

    /// The bundled example must always pass its own validation (schema drift guard).
    func testBundledAgentUsageManifestIsValid() throws {
        // Tests run from the build dir — find the repo's Extensions/ relative to this file.
        let repo = URL(fileURLWithPath: #filePath)          // Tests/PassTests/…
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent("Extensions/agent-usage")
        let data = try Data(contentsOf: dir.appendingPathComponent("extension.json"))
        let m = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        XCTAssertEqual(m.problems(directory: dir), [])
        XCTAssertEqual(m.contributes?.commands?.map(\.id), ["usage", "usage-month"])
    }

    func testDecodesAndValidatesWebWindowManifest() throws {
        let ui = dir.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
        try Data("<!doctype html><title>x</title>".utf8)
            .write(to: ui.appendingPathComponent("index.html"))
        let m = try decode("""
        {
          "apiVersion": 2, "id": "slack-notify", "name": "Dashboard",
          "permissions": ["ui:window", "session:read", "events:attention", "notify"],
          "contributes": {
            "windows": [
              { "id": "dashboard", "title": "Dashboard", "entry": "ui/index.html",
                "width": 900, "height": 600,
                "subscriptions": ["attention.pending", "attention.resolved"] }
            ],
            "commands": [
              { "id": "dashboard", "title": "Open", "run": { "openWindow": "dashboard" } }
            ],
            "actions": {
              "ping": { "notify": { "title": "${input.message}" } }
            }
          }
        }
        """)
        XCTAssertEqual(m.problems(directory: dir), [])
        XCTAssertEqual(m.contributes?.windows?.first?.id, "dashboard")
        XCTAssertEqual(m.contributes?.actions?["ping"]?.notify?.title, "${input.message}")
    }

    func testWebWindowValidationRejectsUnsafeAndUndeclaredContributions() throws {
        let m = try decode("""
        {
          "apiVersion": 1, "id": "slack-notify", "name": "Broken UI",
          "contributes": {
            "windows": [
              { "id": "Bad.ID", "title": "", "entry": "../index.txt", "width": 20,
                "subscriptions": ["attention.pending", "made.up"] },
              { "id": "Bad.ID", "title": "duplicate", "entry": "missing.html" }
            ],
            "commands": [
              { "id": "open", "title": "Open", "run": { "openWindow": "missing" } }
            ]
          }
        }
        """)
        let problems = m.problems(directory: dir)
        func has(_ fragment: String) {
            XCTAssertTrue(problems.contains { $0.contains(fragment) },
                          "missing \"\(fragment)\" in \(problems)")
        }
        has("require apiVersion 2")
        has("id must be lowercase")
        has("duplicate window id")
        has("title must not be empty")
        has("width must be between")
        has("permission \"ui:window\" not declared")
        has("entry must be an HTML file")
        has("unknown event \"made.up\"")
        has("unknown window \"missing\"")
    }

    func testBundledEventMonitorManifestIsValid() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent("Extensions/event-monitor")
        let data = try Data(contentsOf: dir.appendingPathComponent("extension.json"))
        let m = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        XCTAssertEqual(m.problems(directory: dir), [])
        XCTAssertEqual(m.contributes?.commands?.map(\.id), ["events"])
        XCTAssertEqual(m.contributes?.windows?.map(\.id), ["monitor"])
    }

    func testWebResourceCSPInjection() {
        let html = Data("<html><head><title>x</title></head><body>ok</body></html>".utf8)
        let rendered = String(decoding: ExtensionResourceSchemeHandler.injectCSP(into: html),
                              as: UTF8.self)
        XCTAssertTrue(rendered.contains("Content-Security-Policy"))
        XCTAssertTrue(rendered.contains("connect-src 'none'"))
        XCTAssertTrue(rendered.contains("<title>x</title>"))
        XCTAssertEqual(ExtensionResourceSchemeHandler.mimeType(for: "js"), "text/javascript")
    }
}

@MainActor
final class ExtensionStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "ext-store-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    private func install(_ id: String, manifest: String, script: String? = "echo ok") throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("extension.json"))
        if let script {
            try Data("#!/bin/bash\n\(script)\n".utf8).write(to: dir.appendingPathComponent("run.sh"))
        }
    }

    func testLoadsEnablesAndExposesCommands() throws {
        try install("hello", manifest: """
        { "apiVersion": 1, "id": "hello", "name": "Hello",
          "permissions": ["run:script"],
          "contributes": { "commands": [
            { "id": "hi", "title": "Say hi", "run": { "script": "run.sh" } } ] } }
        """)
        let store = ExtensionStore(directory: root, defaults: defaults)
        XCTAssertEqual(store.loaded.map(\.id), ["hello"])
        XCTAssertTrue(store.loaded[0].isValid)

        // Disabled by default — nothing reaches the palette until the user opts in.
        XCTAssertTrue(store.paletteCommands.isEmpty)
        store.setEnabled("hello", true)
        XCTAssertEqual(store.paletteCommands.map(\.token), [">hi"])

        // The enabled set persists (a fresh store over the same defaults sees it).
        let second = ExtensionStore(directory: root, defaults: defaults)
        XCTAssertTrue(second.isEnabled("hello"))
    }

    func testBrokenJSONSurfacesAsLoadErrorNotSilence() throws {
        try install("broken", manifest: "{ not json", script: nil)
        let store = ExtensionStore(directory: root, defaults: defaults)
        XCTAssertTrue(store.loaded.isEmpty)
        XCTAssertEqual(store.loadErrors.map(\.folder), ["broken"])
    }

    func testInvalidExtensionNeverReachesPaletteOrRules() throws {
        // Undeclared permission → problems non-empty → excluded from palette/rules even if
        // the enabled bit is somehow set.
        try install("sneaky", manifest: """
        { "apiVersion": 1, "id": "sneaky", "name": "S",
          "contributes": { "commands": [
            { "id": "x", "title": "t", "run": { "script": "run.sh" } } ],
            "rules": [ { "on": "session.created", "run": { "script": "run.sh" } } ] } }
        """)
        let store = ExtensionStore(directory: root, defaults: defaults)
        XCTAssertFalse(store.loaded[0].isValid)
        store.setEnabled("sneaky", true)
        XCTAssertTrue(store.paletteCommands.isEmpty)
        XCTAssertTrue(store.activeRules.isEmpty)
    }

    func testFolderWithoutManifestIsIgnored() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("stray"),
                                                withIntermediateDirectories: true)
        let store = ExtensionStore(directory: root, defaults: defaults)
        XCTAssertTrue(store.loaded.isEmpty)
        XCTAssertTrue(store.loadErrors.isEmpty)
    }

    func testReloadPicksUpNewExtensions() throws {
        let store = ExtensionStore(directory: root, defaults: defaults)
        XCTAssertTrue(store.loaded.isEmpty)
        try install("late", manifest: """
        { "apiVersion": 1, "id": "late", "name": "Late" }
        """, script: nil)
        store.reload()
        XCTAssertEqual(store.loaded.map(\.id), ["late"])
    }

    func testChangedFilesDisableAnApprovedExtension() throws {
        try install("hello", manifest: """
        { "apiVersion": 1, "id": "hello", "name": "Hello",
          "permissions": ["run:script"],
          "contributes": { "commands": [
            { "id": "hi", "title": "Say hi", "run": { "script": "run.sh" } } ] } }
        """)
        let store = ExtensionStore(directory: root, defaults: defaults)
        store.setEnabled("hello", true)
        XCTAssertTrue(store.isEnabled("hello"))

        let script = root.appendingPathComponent("hello/run.sh")
        try Data("#!/bin/bash\necho changed\n".utf8).write(to: script)
        store.reload()

        XCTAssertFalse(store.isEnabled("hello"))
        XCTAssertTrue(store.wasDisabledAfterChange("hello"))
        XCTAssertTrue(store.paletteCommands.isEmpty)
    }

    func testWindowManagerOpensOneWindowPerContributionAndClosesIt() throws {
        let ui = root.appendingPathComponent("dashboard/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
        try Data("<!doctype html><html><head></head><body>ok</body></html>".utf8)
            .write(to: ui.appendingPathComponent("index.html"))
        try Data("""
        { "apiVersion": 2, "id": "dashboard", "name": "Dashboard",
          "permissions": ["ui:window"],
          "contributes": {
            "windows": [
              { "id": "main", "title": "Dashboard", "entry": "ui/index.html" }
            ],
            "commands": [
              { "id": "open", "title": "Open", "run": { "openWindow": "main" } }
            ]
          } }
        """.utf8).write(to: root.appendingPathComponent("dashboard/extension.json"))

        let store = ExtensionStore(directory: root, defaults: defaults)
        store.setEnabled("dashboard", true)
        let manager = ExtensionWindowManager(store: store)
        let ext = try XCTUnwrap(store.activeExtension(id: "dashboard"))
        let window = try XCTUnwrap(ext.manifest.contributes?.windows?.first)

        XCTAssertNil(manager.open(extension: ext, window: window))
        XCTAssertEqual(manager.openWindowCount, 1)
        XCTAssertNil(manager.open(extension: ext, window: window))
        XCTAssertEqual(manager.openWindowCount, 1)
        manager.close(extensionId: "dashboard")
        XCTAssertEqual(manager.openWindowCount, 0)
    }
}
