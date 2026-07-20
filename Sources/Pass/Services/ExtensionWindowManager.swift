import AppKit
import Foundation
import WebKit

/// Owns extension HTML windows. The app owns the NSWindow/WKWebView lifecycle; an extension owns
/// only local HTML/CSS/JS and communicates through a small JSON bridge.
@MainActor
final class ExtensionWindowManager {
    private struct Key: Hashable {
        let extensionId: String
        let windowId: String
    }

    private let store: ExtensionStore
    private var controllers: [Key: ExtensionWebWindowController] = [:]
    weak var runtime: ExtensionRuntime?
    var openWindowCount: Int { controllers.count }

    init(store: ExtensionStore) {
        self.store = store
    }

    func open(extension ext: ExtensionStore.Loaded, window: ExtensionManifest.Window) -> String? {
        guard ext.isValid, store.isEnabled(ext.id) else { return "extension is disabled" }
        let key = Key(extensionId: ext.id, windowId: window.id)
        if let existing = controllers[key] {
            existing.show()
            return nil
        }
        switch ExtensionManifest.resolveResource(window.entry, in: ext.directory) {
        case .failure(let error): return error.message
        case .success: break
        }

        let controller = ExtensionWebWindowController(
            extensionId: ext.id,
            extensionName: ext.manifest.name,
            manifest: window,
            directory: ext.directory,
            permissions: Set(ext.manifest.permissions ?? []),
            manager: self,
            onClose: { [weak self] in self?.controllers.removeValue(forKey: key) }
        )
        controllers[key] = controller
        controller.show()
        return nil
    }

    func publish(name: String, envelope: [String: Any]) {
        for (key, controller) in controllers {
            guard store.isEnabled(key.extensionId) else { continue }
            controller.publish(name: name, envelope: envelope)
        }
    }

    func close(extensionId: String) {
        let matching = controllers.filter { $0.key.extensionId == extensionId }.map(\.value)
        for controller in matching { controller.close() }
    }

    func closeAll() {
        let all = Array(controllers.values)
        for controller in all { controller.close() }
    }

    fileprivate func snapshot(extensionId: String, permissions: Set<String>) -> [String: Any] {
        runtime?.webSnapshot(extensionId: extensionId, permissions: permissions) ?? [
            "schemaVersion": 1,
            "sessions": [],
        ]
    }

    fileprivate func runAction(extensionId: String, actionId: String,
                               input: [String: String]) async -> String? {
        guard let runtime else { return "extension runtime is not ready" }
        return await runtime.runNamedAction(extensionId: extensionId, actionId: actionId, input: input)
    }
}

/// One extension window and its narrow JS bridge. No filesystem, network, Process, AppModel, or
/// arbitrary native object crosses this boundary.
@MainActor
private final class ExtensionWebWindowController: NSObject, NSWindowDelegate,
                                                   WKNavigationDelegate, WKScriptMessageHandler {
    private let extensionId: String
    private let subscriptions: Set<String>
    private let permissions: Set<String>
    private weak var manager: ExtensionWindowManager?
    private let onClose: () -> Void
    private let webView: WKWebView
    private let window: NSWindow
    private var ready = false
    private var queuedEvents: [[String: Any]] = []
    private var didClose = false

    init(extensionId: String, extensionName: String, manifest: ExtensionManifest.Window,
         directory: URL, permissions: Set<String>, manager: ExtensionWindowManager,
         onClose: @escaping () -> Void) {
        self.extensionId = extensionId
        subscriptions = Set(manifest.subscriptions ?? [])
        self.permissions = permissions
        self.manager = manager
        self.onClose = onClose

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ExtensionResourceSchemeHandler(extensionId: extensionId,
                                                                   directory: directory),
                                   forURLScheme: ExtensionResourceSchemeHandler.scheme)
        config.userContentController.addUserScript(WKUserScript(
            source: ExtensionBridgeBootstrap.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: .zero, configuration: config)

        let width = min(max(manifest.width ?? 960, 320), 1920)
        let height = min(max(manifest.height ?? 640, 240), 1200)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = manifest.title.isEmpty ? extensionName : manifest.title
        window.minSize = NSSize(width: 320, height: 240)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]

        super.init()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: ExtensionBridgeBootstrap.handlerName)
        window.delegate = self

        var components = URLComponents()
        components.scheme = ExtensionResourceSchemeHandler.scheme
        components.host = extensionId
        components.path = "/" + manifest.entry
        if let url = components.url { webView.load(URLRequest(url: url)) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard !didClose else { return }
        window.close()
    }

    func publish(name: String, envelope: [String: Any]) {
        guard subscriptions.contains(name) else { return }
        if ready { sendEvent(envelope) }
        else {
            // A page load is short; cap the queue so an unhealthy page cannot retain an
            // unbounded event history. The opening snapshot remains the source of truth.
            queuedEvents.append(envelope)
            if queuedEvents.count > 100 { queuedEvents.removeFirst(queuedEvents.count - 100) }
        }
    }

    func windowWillClose(_ notification: Notification) { finishClose() }

    private func finishClose() {
        guard !didClose else { return }
        didClose = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: ExtensionBridgeBootstrap.handlerName
        )
        onClose()
    }

    // MARK: Navigation boundary

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == ExtensionResourceSchemeHandler.scheme || scheme == "about"
                        ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The bootstrap posts `ready` at document start; didFinish is a second safety net for a
        // page that overwrote the hook before its first message crossed the process boundary.
        markReady()
    }

    // MARK: JS bridge

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == ExtensionBridgeBootstrap.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            markReady()

        case "getSnapshot":
            guard let requestId = body["requestId"] as? String else { return }
            guard permissions.contains("session:read") else {
                resolve(requestId, ok: false, payload: "permission \"session:read\" not declared")
                return
            }
            resolve(requestId, ok: true,
                    payload: manager?.snapshot(extensionId: extensionId, permissions: permissions) ?? [:])

        case "runAction":
            guard let requestId = body["requestId"] as? String,
                  let actionId = body["actionId"] as? String else { return }
            let input = Self.sanitizedInput(body["input"])
            Task { [weak self] in
                guard let self else { return }
                let error = await manager?.runAction(extensionId: extensionId,
                                                     actionId: actionId, input: input)
                if let error { resolve(requestId, ok: false, payload: error) }
                else { resolve(requestId, ok: true, payload: ["ok": true]) }
            }

        case "closeWindow":
            close()

        default:
            if let requestId = body["requestId"] as? String {
                resolve(requestId, ok: false, payload: "unknown bridge request")
            }
        }
    }

    private static func sanitizedInput(_ raw: Any?) -> [String: String] {
        guard let values = raw as? [String: Any] else { return [:] }
        var clean: [String: String] = [:]
        for key in values.keys.sorted().prefix(32) {
            guard key.count <= 80, ExtensionManifest.isValidInputKey(key),
                  let value = values[key] as? String else { continue }
            clean[key] = String(value.prefix(8_192))
        }
        return clean
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        let queued = queuedEvents
        queuedEvents.removeAll()
        for event in queued { sendEvent(event) }
    }

    private func sendEvent(_ event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__passReceive(\(json));")
    }

    private func resolve(_ requestId: String, ok: Bool, payload: Any) {
        let args: [Any] = [requestId, ok, payload]
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__passResolve.apply(null, \(json));")
    }
}

enum ExtensionBridgeBootstrap {
    static let handlerName = "passExtension"

    static let source = #"""
    (() => {
      const listeners = new Map();
      const pending = new Map();
      let nextRequest = 0;
      const post = (message) => window.webkit.messageHandlers.passExtension.postMessage(message);
      const request = (type, payload = {}) => new Promise((resolve, reject) => {
        const requestId = `${Date.now()}-${++nextRequest}`;
        pending.set(requestId, { resolve, reject });
        post({ type, requestId, ...payload });
      });

      const api = {
        on(name, handler) {
          if (typeof name !== "string" || typeof handler !== "function") {
            throw new TypeError("pass.on(name, handler) requires a string and function");
          }
          const bucket = listeners.get(name) || new Set();
          bucket.add(handler); listeners.set(name, bucket);
          return () => bucket.delete(handler);
        },
        getSnapshot() { return request("getSnapshot"); },
        runAction(actionId, input = {}) { return request("runAction", { actionId, input }); },
        closeWindow() { post({ type: "closeWindow" }); }
      };
      Object.freeze(api);
      Object.defineProperty(window, "pass", { value: api, writable: false, configurable: false });

      window.__passReceive = (event) => {
        for (const name of [event.name, "*"]) {
          for (const handler of listeners.get(name) || []) {
            try { handler(event); } catch (error) { console.error("pass event handler", error); }
          }
        }
      };
      window.__passResolve = (requestId, ok, payload) => {
        const target = pending.get(requestId);
        if (!target) return;
        pending.delete(requestId);
        if (ok) target.resolve(payload);
        else target.reject(new Error(typeof payload === "string" ? payload : "bridge request failed"));
      };
      post({ type: "ready" });
    })();
    """#
}

/// Serves only reviewed files underneath one extension directory. HTML receives a restrictive
/// CSP at load time; relative CSS/JS/assets keep working through the same private scheme.
final class ExtensionResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pass-extension"
    private static let maxResourceBytes = 20 * 1024 * 1024
    private let extensionId: String
    private let directory: URL

    init(extensionId: String, directory: URL) {
        self.extensionId = extensionId
        self.directory = directory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme == Self.scheme,
              requestURL.host == extensionId else {
            fail(urlSchemeTask, code: .fileReadNoPermission)
            return
        }
        let relative = String(requestURL.path.drop(while: { $0 == "/" }))
        let url: URL
        switch ExtensionManifest.resolveResource(relative, in: directory) {
        case .failure:
            fail(urlSchemeTask, code: .fileReadNoSuchFile)
            return
        case .success(let resolved): url = resolved
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= Self.maxResourceBytes else {
            fail(urlSchemeTask, code: .fileReadTooLarge)
            return
        }
        let mime = Self.mimeType(for: url.pathExtension)
        let delivered = mime == "text/html" ? Self.injectCSP(into: data) : data
        let response = URLResponse(url: requestURL, mimeType: mime,
                                   expectedContentLength: delivered.count,
                                   textEncodingName: mime.hasPrefix("text/") || mime.contains("javascript")
                                   ? "utf-8" : nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(delivered)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, code: CocoaError.Code) {
        task.didFailWithError(CocoaError(code))
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    static func injectCSP(into data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) else { return data }
        let policy = "default-src 'self'; connect-src 'none'; img-src 'self' data:; "
            + "style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
            + "font-src 'self'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: meta, at: head.upperBound)
        } else {
            html = meta + html
        }
        return Data(html.utf8)
    }
}

private extension ExtensionManifest {
    static func isValidInputKey(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
