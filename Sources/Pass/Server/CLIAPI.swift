import Foundation

// JSON shapes for the /cli/* control plane (BROWSER.md §5.4). The PassCli target keeps a
// mirrored copy (separate target, no shared framework — same rule as PassShare/ShareAPI).
// Keep the two in sync.

struct CLIOpenRequest: Codable {
    var session: String? = nil
    var url: String
    var background: Bool? = nil
}

struct CLIOpenResponse: Codable {
    var ok: Bool
    var tabId: String? = nil
    var resolvedURL: String? = nil
    var error: String? = nil
}

struct CLICloseRequest: Codable {
    var session: String? = nil
}

struct CLISimpleResponse: Codable {
    var ok: Bool
    var error: String? = nil
}

struct CLITabsResponse: Codable {
    struct Tab: Codable {
        var id: String
        var session: String
        var url: String
        var title: String? = nil
        var unseen: Bool
    }
    var ok: Bool
    var tabs: [Tab]
}

struct CLIScreenshotRequest: Codable {
    var session: String? = nil
    var path: String?    // absolute (or ~) — omitted: pass picks one under ~/.pass/screenshots
}

struct CLIScreenshotResponse: Codable {
    var ok: Bool
    var path: String? = nil
    var error: String? = nil
}

struct CLIReadRequest: Codable {
    var session: String? = nil
    var format: String?  // "text" (default, innerText) | "html" (outerHTML)
}

struct CLIReadResponse: Codable {
    var ok: Bool
    var content: String? = nil
    var truncated: Bool? = nil
    var error: String? = nil
}

struct CLIExtensionValidateRequest: Codable {
    var path: String
}

struct CLIExtensionValidateResponse: Codable {
    var ok: Bool
    var id: String? = nil
    var name: String? = nil
    var permissions: [String] = []
    var problems: [String] = []
    var error: String? = nil
}

/// Serves passcli: opens/closes/lists embedded-browser pages and the observation verbs
/// (screenshot/read). Always answers 200 + `{ok,…}` JSON — errors ride in the body so the
/// CLI can print them verbatim. Loopback-only, same trust posture as /hook/* and /share/*:
/// agents in pass sessions already hold user-level shell power; this adds structure, not
/// privilege (BROWSER.md §6).
@MainActor
enum CLIAPI {
    // MARK: browser open / close / tabs

    static func open(_ appModel: AppModel, body: Data) async -> Data {
        guard body.count <= PassConfig.cliMaxBodyBytes else {
            return encode(CLIOpenResponse(ok: false, error: "request too large"))
        }
        guard let req = try? JSONDecoder().decode(CLIOpenRequest.self, from: body) else {
            return encode(CLIOpenResponse(ok: false, error: "bad request"))
        }
        guard req.url.utf8.count <= PassConfig.cliMaxURLBytes else {
            return encode(CLIOpenResponse(ok: false, error: "url too long"))
        }
        guard let session = target(appModel, req.session) else {
            return encode(CLIOpenResponse(ok: false, error: missingSession(req.session)))
        }
        // Relative file paths resolve against the session's cwd (the CLI usually absolutizes
        // already; this is the server-side fallback).
        switch URLNormalizer.normalize(req.url, fileBase: session.cwd) {
        case .failure(let failure):
            return encode(CLIOpenResponse(ok: false, error: failure.message))
        case .success(let url):
            appModel.openBrowserFromCLI(session: session.name, url: url,
                                        background: req.background ?? false)
            let tab = appModel.browser?.tab(for: session.name)
            return encode(CLIOpenResponse(ok: true, tabId: tab?.id.uuidString,
                                          resolvedURL: url.absoluteString))
        }
    }

    static func close(_ appModel: AppModel, body: Data) -> Data {
        guard let req = try? JSONDecoder().decode(CLICloseRequest.self, from: body) else {
            return encode(CLISimpleResponse(ok: false, error: "bad request"))
        }
        guard let session = target(appModel, req.session) else {
            return encode(CLISimpleResponse(ok: false, error: missingSession(req.session)))
        }
        guard appModel.browser?.tab(for: session.name) != nil else {
            return encode(CLISimpleResponse(ok: false, error: "no open page for '\(session.name)'"))
        }
        appModel.browser?.close(session: session.name)
        return encode(CLISimpleResponse(ok: true))
    }

    static func tabs(_ appModel: AppModel) -> Data {
        let browser = appModel.browser
        let tabs = (browser?.tabs ?? []).map { tab in
            CLITabsResponse.Tab(id: tab.id.uuidString, session: tab.sessionName,
                                url: tab.url.absoluteString, title: tab.title,
                                unseen: browser?.hasUnseen(tab.sessionName) ?? false)
        }
        return encode(CLITabsResponse(ok: true, tabs: tabs))
    }

    // MARK: observation (v1.5 — screenshot / read)

    static func screenshot(_ appModel: AppModel, body: Data) async -> Data {
        guard let req = try? JSONDecoder().decode(CLIScreenshotRequest.self, from: body) else {
            return encode(CLIScreenshotResponse(ok: false, error: "bad request"))
        }
        guard let session = target(appModel, req.session) else {
            return encode(CLIScreenshotResponse(ok: false, error: missingSession(req.session)))
        }
        guard let tab = appModel.browser?.tab(for: session.name) else {
            return encode(CLIScreenshotResponse(
                ok: false, error: "no open page — run `passcli browser open <url>` first"))
        }

        let path: String
        if let p = req.path, !p.isEmpty {
            let expanded = NSString(string: p).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                return encode(CLIScreenshotResponse(ok: false, error: "path must be absolute"))
            }
            path = expanded
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            path = PassConfig.screenshotsDir + "/\(session.name)-\(fmt.string(from: Date())).png"
        }

        // A hidden panel/split renders stale or blank (S6.2) — reveal the split, surface the
        // panel (non-activating: the user's editor keeps focus), and give the workspace a
        // beat to mount and paint.
        appModel.browser?.reveal(session.name)
        if !appModel.panelVisible {
            appModel.panelController?.show(preselecting: session.name)
            try? await Task.sleep(for: .milliseconds(600))
        }
        appModel.webViews?.load(tab)
        await appModel.webViews?.awaitLoaded(tab.id)
        guard let png = await appModel.webViews?.snapshotPNG(tab.id) else {
            return encode(CLIScreenshotResponse(ok: false, error: "could not capture the page"))
        }
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            return encode(CLIScreenshotResponse(ok: false, error: error.localizedDescription))
        }
        return encode(CLIScreenshotResponse(ok: true, path: path))
    }

    static func read(_ appModel: AppModel, body: Data) async -> Data {
        guard let req = try? JSONDecoder().decode(CLIReadRequest.self, from: body) else {
            return encode(CLIReadResponse(ok: false, error: "bad request"))
        }
        guard let session = target(appModel, req.session) else {
            return encode(CLIReadResponse(ok: false, error: missingSession(req.session)))
        }
        guard let tab = appModel.browser?.tab(for: session.name) else {
            return encode(CLIReadResponse(
                ok: false, error: "no open page — run `passcli browser open <url>` first"))
        }
        let html = (req.format ?? "text").lowercased() == "html"
        appModel.webViews?.load(tab)
        await appModel.webViews?.awaitLoaded(tab.id)
        guard let raw = await appModel.webViews?.readContent(tab.id, html: html) else {
            return encode(CLIReadResponse(ok: false, error: "could not read the page"))
        }
        var content = raw
        var truncated = false
        if content.utf8.count > PassConfig.cliMaxReadBytes {
            content = String(decoding: Data(content.utf8).prefix(PassConfig.cliMaxReadBytes),
                             as: UTF8.self)
            truncated = true
        }
        return encode(CLIReadResponse(ok: true, content: content, truncated: truncated ? true : nil))
    }

    // MARK: extension authoring

    /// Validate a draft with the exact decoder/catalog/runtime rules the app uses. This endpoint
    /// is deliberately read-only: validation never installs, approves, or enables an extension.
    static func validateExtension(body: Data, fileManager: FileManager = .default) -> Data {
        guard body.count <= PassConfig.cliMaxBodyBytes else {
            return encode(CLIExtensionValidateResponse(ok: false, error: "request too large"))
        }
        guard let request = try? JSONDecoder().decode(CLIExtensionValidateRequest.self, from: body) else {
            return encode(CLIExtensionValidateResponse(ok: false, error: "bad request"))
        }
        let expanded = NSString(string: request.path).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return encode(CLIExtensionValidateResponse(ok: false, error: "path must be absolute"))
        }
        let directory = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return encode(CLIExtensionValidateResponse(ok: false, error: "extension folder not found"))
        }
        let manifestURL = directory.appendingPathComponent("extension.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return encode(CLIExtensionValidateResponse(
                ok: false, problems: ["extension.json is missing or unreadable"]))
        }
        guard data.count <= 1024 * 1024 else {
            return encode(CLIExtensionValidateResponse(
                ok: false, problems: ["extension.json is larger than 1 MB"]))
        }
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        } catch {
            return encode(CLIExtensionValidateResponse(
                ok: false, problems: ["extension.json: \(error.localizedDescription)"]))
        }
        let problems = manifest.problems(directory: directory, fileManager: fileManager)
        return encode(CLIExtensionValidateResponse(
            ok: problems.isEmpty,
            id: manifest.id,
            name: manifest.name,
            permissions: (manifest.permissions ?? []).sorted(),
            problems: problems))
    }

    // MARK: helpers

    /// The request's target session — must be a live one (v1 has no session-less tabs).
    private static func target(_ appModel: AppModel, _ name: String?) -> Session? {
        guard let name, !name.isEmpty else { return nil }
        return appModel.sessions?.session(named: name)
    }

    static func missingSession(_ name: String?) -> String {
        guard let name, !name.isEmpty else {
            return "no target session — pass --session, or run inside a pass tmux session ($PASS_SESSION)"
        }
        return "unknown session '\(name)' — check tmux ls (pass-* sessions)"
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)
    }
}
