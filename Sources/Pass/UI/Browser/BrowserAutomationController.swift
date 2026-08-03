import AppKit
import WebKit

struct BrowserAutomationViewport: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let documentWidth: Double
    let documentHeight: Double
}

struct BrowserAutomationElement: Codable, Equatable {
    let ref: String
    let role: String
    let name: String
    let tag: String
    let type: String?
    let value: String?
    let disabled: Bool?
    let checked: Bool?
    let selected: Bool?
    let expanded: Bool?
    let sensitive: Bool?
}

struct BrowserAutomationSnapshot: Codable, Equatable {
    let revision: Int
    let url: String
    let title: String
    let viewport: BrowserAutomationViewport
    let elements: [BrowserAutomationElement]
    let truncated: Bool
}

struct BrowserAutomationAction: Equatable {
    let action: String
    let ref: String?
    let text: String?
    let key: String?
    let direction: String?
    let amount: Double?
    let revision: Int?

    init(
        action: String,
        ref: String? = nil,
        text: String? = nil,
        key: String? = nil,
        direction: String? = nil,
        amount: Double? = nil,
        revision: Int? = nil
    ) {
        self.action = action
        self.ref = ref
        self.text = text
        self.key = key
        self.direction = direction
        self.amount = amount
        self.revision = revision
    }
}

struct BrowserAutomationActionResult: Codable, Equatable {
    let revision: Int
    let url: String
    let title: String
    let viewport: BrowserAutomationViewport
    let target: BrowserAutomationElement?
    let snapshotRecommended: Bool
}

enum BrowserAutomationError: LocalizedError, Equatable {
    case tabNotFound
    case snapshotRequired
    case staleRevision(expected: Int, actual: Int)
    case unknownReference(String)
    case staleReference(String)
    case hidden(String)
    case disabled(String)
    case covered(String)
    case unsupportedAction(String)
    case missingArgument(String)
    case invalidArgument(String)
    case javaScript(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .tabNotFound:
            return "tab_not_found: no live browser view exists for this tab"
        case .snapshotRequired:
            return "snapshot_required: take a new browser snapshot before acting"
        case .staleRevision(let expected, let actual):
            return "stale_revision: requested \(expected), latest revision is \(actual)"
        case .unknownReference(let ref):
            return "unknown_ref: \(ref) is not in the latest browser snapshot"
        case .staleReference(let ref):
            return "stale_ref: \(ref) no longer identifies the observed element"
        case .hidden(let ref):
            return "element_hidden: \(ref) is not currently visible"
        case .disabled(let ref):
            return "element_disabled: \(ref) is disabled"
        case .covered(let ref):
            return "element_covered: \(ref) is covered by another element"
        case .unsupportedAction(let action):
            return "unsupported_action: \(action)"
        case .missingArgument(let argument):
            return "missing_argument: \(argument)"
        case .invalidArgument(let message):
            return "invalid_argument: \(message)"
        case .javaScript(let message):
            return "javascript_error: \(message)"
        case .invalidResponse:
            return "invalid_response: browser automation returned malformed data"
        }
    }
}

/// Runs the agent-facing browser protocol in an isolated JavaScript content world. The page
/// cannot read or modify the element-ref map, while the map still points at the real DOM.
@MainActor
final class BrowserAutomationController {
    private static let contentWorld = WKContentWorld.world(
        name: "dev.lightsoft.pass.browser-automation"
    )
    private static let fallbackViewport = NSSize(width: 1280, height: 800)

    private weak var webView: WKWebView?
    private var revision = 0
    private var snapshotDocumentURL: String?
    private var snapshotHistoryItem: WKBackForwardListItem?
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(webView: WKWebView) {
        self.webView = webView
    }

    func snapshot(includeOffscreen: Bool) async throws -> BrowserAutomationSnapshot {
        try await serialized {
            try await snapshotUnserialized(includeOffscreen: includeOffscreen)
        }
    }

    func perform(_ request: BrowserAutomationAction) async throws -> BrowserAutomationActionResult {
        try await serialized {
            try await performUnserialized(request)
        }
    }

    private func snapshotUnserialized(
        includeOffscreen: Bool
    ) async throws -> BrowserAutomationSnapshot {
        let webView = try liveWebView()
        ensureUsableViewport(webView)
        let resultRevision = revision + 1

        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                Self.snapshotScript,
                arguments: [
                    "includeOffscreen": includeOffscreen,
                    "resultRevision": resultRevision,
                ],
                in: nil,
                contentWorld: Self.contentWorld
            )
        } catch {
            throw BrowserAutomationError.javaScript(error.localizedDescription)
        }

        let snapshot = try Self.decode(BrowserAutomationSnapshot.self, from: value)
        revision = snapshot.revision
        snapshotDocumentURL = webView.url?.absoluteString ?? snapshot.url
        snapshotHistoryItem = webView.backForwardList.currentItem
        return snapshot
    }

    private func performUnserialized(
        _ request: BrowserAutomationAction
    ) async throws -> BrowserAutomationActionResult {
        let webView = try liveWebView()
        ensureUsableViewport(webView)

        guard revision > 0, let snapshotDocumentURL else {
            throw BrowserAutomationError.snapshotRequired
        }
        if webView.url?.absoluteString != snapshotDocumentURL {
            throw BrowserAutomationError.snapshotRequired
        }
        if let snapshotHistoryItem,
           let currentItem = webView.backForwardList.currentItem,
           snapshotHistoryItem !== currentItem {
            throw BrowserAutomationError.snapshotRequired
        }

        if let requestedRevision = request.revision, requestedRevision != revision {
            throw BrowserAutomationError.staleRevision(
                expected: requestedRevision,
                actual: revision
            )
        }

        let actionName = request.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.supportedActions.contains(actionName) else {
            throw BrowserAutomationError.unsupportedAction(request.action)
        }

        let resultRevision = revision + 1
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                Self.actionScript,
                arguments: [
                    "actionName": actionName,
                    "hasRef": request.ref != nil,
                    "reference": request.ref ?? "",
                    "hasText": request.text != nil,
                    "textValue": request.text ?? "",
                    "hasKey": request.key != nil,
                    "keyValue": request.key ?? "",
                    "hasDirection": request.direction != nil,
                    "directionValue": request.direction ?? "",
                    "hasAmount": request.amount != nil,
                    "amountValue": request.amount ?? 0,
                    "stateRevision": revision,
                    "resultRevision": resultRevision,
                ],
                in: nil,
                contentWorld: Self.contentWorld
            )
        } catch {
            throw BrowserAutomationError.javaScript(error.localizedDescription)
        }

        let execution = try Self.decode(ActionExecutionEnvelope.self, from: value)
        if let failure = execution.error {
            throw Self.map(failure, fallbackRevision: revision)
        }
        guard execution.ok else {
            throw BrowserAutomationError.invalidResponse
        }

        revision = resultRevision
        // Give input/change handlers, layout and same-document scrolling a short turn to settle.
        try? await Task.sleep(for: .milliseconds(80))
        let page = try await pageInfo(webView)
        return BrowserAutomationActionResult(
            revision: resultRevision,
            url: page.url,
            title: page.title,
            viewport: page.viewport,
            target: execution.target,
            snapshotRecommended: true
        )
    }

    /// Main-actor methods can still interleave at `await`. Keep content-world state changes in
    /// request order so two simultaneous CLI calls cannot reuse or regress a revision.
    private func serialized<T>(_ operation: () async throws -> T) async throws -> T {
        await beginOperation()
        do {
            let result = try await operation()
            endOperation()
            return result
        } catch {
            endOperation()
            throw error
        }
    }

    private func beginOperation() async {
        if !operationInProgress {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func endOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func liveWebView() throws -> WKWebView {
        guard let webView else { throw BrowserAutomationError.tabNotFound }
        return webView
    }

    /// A pooled webview can be automated before SwiftUI has attached and sized it. WebKit uses
    /// the view bounds as `innerWidth/innerHeight`, so supply a browser-like detached viewport.
    private func ensureUsableViewport(_ webView: WKWebView) {
        guard webView.bounds.width < 2 || webView.bounds.height < 2 else { return }
        webView.setFrameSize(Self.fallbackViewport)
        webView.layoutSubtreeIfNeeded()
    }

    private func pageInfo(_ webView: WKWebView) async throws -> PageInfo {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let value = try await webView.callAsyncJavaScript(
                    Self.pageInfoScript,
                    arguments: [:],
                    in: nil,
                    contentWorld: Self.contentWorld
                )
                return try Self.decode(PageInfo.self, from: value)
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
        }
        throw BrowserAutomationError.javaScript(
            lastError?.localizedDescription ?? "could not read the current page"
        )
    }

    private static let supportedActions: Set<String> = [
        "click", "fill", "type", "select", "press", "scroll",
    ]

    private struct PageInfo: Decodable {
        let url: String
        let title: String
        let viewport: BrowserAutomationViewport
    }

    private struct ActionExecutionEnvelope: Decodable {
        let ok: Bool
        let target: BrowserAutomationElement?
        let error: ScriptFailure?
    }

    private struct ScriptFailure: Decodable {
        let code: String
        let message: String?
        let ref: String?
        let argument: String?
        let expected: Int?
        let actual: Int?
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: Any?) throws -> T {
        guard let json = value as? String, let data = json.data(using: .utf8) else {
            throw BrowserAutomationError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BrowserAutomationError.invalidResponse
        }
    }

    private static func map(
        _ failure: ScriptFailure,
        fallbackRevision: Int
    ) -> BrowserAutomationError {
        switch failure.code {
        case "snapshot_required":
            return .snapshotRequired
        case "stale_revision":
            return .staleRevision(
                expected: failure.expected ?? fallbackRevision,
                actual: failure.actual ?? fallbackRevision
            )
        case "unknown_ref":
            return .unknownReference(failure.ref ?? "?")
        case "stale_ref":
            return .staleReference(failure.ref ?? "?")
        case "hidden":
            return .hidden(failure.ref ?? "?")
        case "disabled":
            return .disabled(failure.ref ?? "?")
        case "covered":
            return .covered(failure.ref ?? "?")
        case "missing_argument":
            return .missingArgument(failure.argument ?? failure.message ?? "required value")
        case "invalid_argument":
            return .invalidArgument(failure.message ?? "invalid action argument")
        case "unsupported_action":
            return .unsupportedAction(failure.message ?? "unknown")
        default:
            return .javaScript(failure.message ?? failure.code)
        }
    }

    private static let pageInfoScript = #"""
    function bounded(value, limit) {
      return String(value == null ? "" : value).slice(0, limit);
    }
    function viewport() {
      const scrolling = document.scrollingElement || document.documentElement;
      const root = document.documentElement;
      const body = document.body;
      return {
        x: Number(window.scrollX || scrolling?.scrollLeft || 0),
        y: Number(window.scrollY || scrolling?.scrollTop || 0),
        width: Number(window.innerWidth || root?.clientWidth || 0),
        height: Number(window.innerHeight || root?.clientHeight || 0),
        documentWidth: Number(Math.max(
          scrolling?.scrollWidth || 0, root?.scrollWidth || 0, body?.scrollWidth || 0
        )),
        documentHeight: Number(Math.max(
          scrolling?.scrollHeight || 0, root?.scrollHeight || 0, body?.scrollHeight || 0
        ))
      };
    }
    return JSON.stringify({
      url: bounded(document.location.href, 8192),
      title: bounded(document.title, 2000),
      viewport: viewport()
    });
    """#

    private static let snapshotScript = #"""
    const STATE_KEY = "__passBrowserAutomationState";
    const state = globalThis[STATE_KEY] || (globalThis[STATE_KEY] = {
      nextRef: 1,
      ids: new WeakMap(),
      refs: new Map(),
      knownRefs: new Set(),
      revision: 0,
      hasSnapshot: false,
      snapshotURL: null
    });
    const interactiveRoles = new Set([
      "button", "link", "checkbox", "radio", "textbox", "searchbox", "combobox",
      "listbox", "option", "menuitem", "menuitemcheckbox", "menuitemradio",
      "switch", "slider", "spinbutton", "tab", "treeitem"
    ]);

    function clean(value) {
      return String(value == null ? "" : value).replace(/\s+/g, " ").trim().slice(0, 500);
    }
    function bounded(value, limit) {
      return String(value == null ? "" : value).slice(0, limit);
    }
    function currentDocumentURL() {
      return String(document.location.href || "");
    }
    function attributeBoolean(el, name) {
      if (!el.hasAttribute(name)) return null;
      return el.getAttribute(name) !== "false";
    }
    function roleOf(el) {
      const explicit = clean(el.getAttribute("role")).toLowerCase().split(" ")[0];
      if (explicit) return explicit;
      const tag = el.localName;
      if (tag === "a" && el.hasAttribute("href")) return "link";
      if (tag === "button") return "button";
      if (tag === "select") return el.multiple ? "listbox" : "combobox";
      if (tag === "textarea") return "textbox";
      if (tag === "summary") return "button";
      if (tag === "option") return "option";
      if (tag === "input") {
        const type = (el.type || "text").toLowerCase();
        if (["button", "submit", "reset", "image"].includes(type)) return "button";
        if (type === "checkbox") return "checkbox";
        if (type === "radio") return "radio";
        if (type === "range") return "slider";
        if (type === "number") return "spinbutton";
        if (type === "search") return "searchbox";
        return "textbox";
      }
      return tag || "element";
    }
    function lookupLabelledBy(el) {
      const ids = clean(el.getAttribute("aria-labelledby")).split(" ").filter(Boolean);
      if (!ids.length) return "";
      const root = el.getRootNode();
      return clean(ids.map(id => {
        const found = typeof root.getElementById === "function"
          ? root.getElementById(id)
          : document.getElementById(id);
        return found?.innerText || found?.textContent || "";
      }).join(" "));
    }
    function nameOf(el) {
      const labelled = lookupLabelledBy(el);
      if (labelled) return labelled;
      const aria = clean(el.getAttribute("aria-label"));
      if (aria) return aria;
      if (el.labels && el.labels.length) {
        const labels = clean(Array.from(el.labels).map(label => label.innerText).join(" "));
        if (labels) return labels;
      }
      const tag = el.localName;
      const type = clean(el.getAttribute("type")).toLowerCase();
      if (tag === "img" || type === "image") {
        const alt = clean(el.getAttribute("alt"));
        if (alt) return alt;
      }
      if (tag === "input" && ["button", "submit", "reset"].includes(type)) {
        const value = clean(el.value);
        if (value) return value;
      }
      const text = clean(el.innerText || el.textContent);
      if (text) return text;
      return clean(
        el.getAttribute("placeholder") ||
        el.getAttribute("title") ||
        el.getAttribute("name") ||
        ""
      );
    }
    function isInteractive(el) {
      const tag = el.localName;
      if (tag === "a" && el.hasAttribute("href")) return true;
      if (["button", "select", "textarea", "summary"].includes(tag)) return true;
      if (tag === "input" && (el.type || "text").toLowerCase() !== "hidden") return true;
      if (el.isContentEditable) return true;
      if (el.tabIndex >= 0) return true;
      if (interactiveRoles.has(roleOf(el))) return true;
      return el.hasAttribute("onclick");
    }
    function isStyleVisible(el) {
      if (!el.isConnected) return false;
      let current = el;
      while (current && current.nodeType === Node.ELEMENT_NODE) {
        if (current.hidden || current.hasAttribute("inert")) return false;
        const style = getComputedStyle(current);
        if (style.display === "none" || style.visibility === "hidden" ||
            style.visibility === "collapse" || Number(style.opacity) <= 0) return false;
        const root = current.getRootNode();
        current = current.parentElement || root?.host || null;
      }
      return Array.from(el.getClientRects()).some(rect => rect.width > 0 && rect.height > 0);
    }
    function isInViewport(el) {
      return Array.from(el.getClientRects()).some(rect =>
        rect.width > 0 && rect.height > 0 &&
        rect.right > 0 && rect.bottom > 0 &&
        rect.left < window.innerWidth && rect.top < window.innerHeight
      );
    }
    function optionalBoolean(value) {
      return value == null ? undefined : Boolean(value);
    }
    function describe(el, ref) {
      const tag = el.localName || "";
      const type = clean(el.getAttribute("type")).toLowerCase();
      const password = tag === "input" && type === "password";
      const result = {
        ref,
        role: roleOf(el),
        name: nameOf(el),
        tag
      };
      if (type) result.type = type;
      if (password) {
        result.sensitive = true;
      } else if (tag === "input" || tag === "textarea" || tag === "select") {
        result.value = String(el.value == null ? "" : el.value).slice(0, 2000);
      } else if (el.isContentEditable) {
        result.value = String(el.innerText || el.textContent || "").slice(0, 2000);
      }
      const ariaDisabled = attributeBoolean(el, "aria-disabled");
      if ("disabled" in el || ariaDisabled != null) {
        result.disabled = Boolean(el.disabled) || Boolean(el.matches?.(":disabled")) ||
          ariaDisabled === true;
      }
      const ariaChecked = attributeBoolean(el, "aria-checked");
      if ("checked" in el || ariaChecked != null) {
        result.checked = Boolean(el.checked) || ariaChecked === true;
      }
      const ariaSelected = attributeBoolean(el, "aria-selected");
      if ("selected" in el || ariaSelected != null) {
        result.selected = Boolean(el.selected) || ariaSelected === true;
      }
      const ariaExpanded = attributeBoolean(el, "aria-expanded");
      if (ariaExpanded != null) result.expanded = ariaExpanded;
      return result;
    }
    function refFor(el) {
      let ref = state.ids.get(el);
      if (!ref) {
        ref = `@e${state.nextRef++}`;
        state.ids.set(el, ref);
        state.knownRefs.add(ref);
      }
      return ref;
    }
    function fingerprint(el) {
      const form = el.form || null;
      const ariaChecked = attributeBoolean(el, "aria-checked");
      const ariaSelected = attributeBoolean(el, "aria-selected");
      const ariaExpanded = attributeBoolean(el, "aria-expanded");
      const ariaReadonly = attributeBoolean(el, "aria-readonly");
      return JSON.stringify({
        documentURL: bounded(currentDocumentURL(), 8192),
        tag: el.localName || "",
        role: roleOf(el),
        name: nameOf(el),
        type: clean(el.getAttribute("type")).toLowerCase(),
        id: clean(el.id),
        fieldName: clean(el.getAttribute("name")),
        href: bounded(el.href || el.getAttribute("href") || "", 2048),
        rawHref: bounded(el.getAttribute("href") || "", 2048),
        form: form ? {
          id: clean(form.id),
          name: clean(form.getAttribute("name")),
          action: bounded(form.action || form.getAttribute("action") || "", 2048),
          rawAction: bounded(form.getAttribute("action") || "", 2048),
          method: clean(form.method)
        } : null,
        disabled: Boolean(el.disabled) || Boolean(el.matches?.(":disabled")) ||
          attributeBoolean(el, "aria-disabled") === true,
        checked: ("checked" in el) ? Boolean(el.checked) : ariaChecked,
        selected: ("selected" in el) ? Boolean(el.selected) : ariaSelected,
        expanded: ariaExpanded,
        readonly: Boolean(el.readOnly) || el.hasAttribute("readonly") ||
          ariaReadonly === true ||
          (el.hasAttribute("contenteditable") && !el.isContentEditable),
        value: (el.localName === "input" || el.localName === "textarea" ||
                el.localName === "select") ? bounded(el.value, 2000) :
          el.isContentEditable ? bounded(el.textContent, 2000) : null,
        valueTail: (el.localName === "input" || el.localName === "textarea" ||
                    el.localName === "select") ? bounded(String(el.value ?? "").slice(-2000), 2000) :
          el.isContentEditable ? bounded(String(el.textContent ?? "").slice(-2000), 2000) : null,
        valueLength: (el.localName === "input" || el.localName === "textarea" ||
                      el.localName === "select") ? String(el.value ?? "").length :
          el.isContentEditable ? String(el.textContent ?? "").length : null
      });
    }
    function viewport() {
      const scrolling = document.scrollingElement || document.documentElement;
      const root = document.documentElement;
      const body = document.body;
      return {
        x: Number(window.scrollX || scrolling?.scrollLeft || 0),
        y: Number(window.scrollY || scrolling?.scrollTop || 0),
        width: Number(window.innerWidth || root?.clientWidth || 0),
        height: Number(window.innerHeight || root?.clientHeight || 0),
        documentWidth: Number(Math.max(
          scrolling?.scrollWidth || 0, root?.scrollWidth || 0, body?.scrollWidth || 0
        )),
        documentHeight: Number(Math.max(
          scrolling?.scrollHeight || 0, root?.scrollHeight || 0, body?.scrollHeight || 0
        ))
      };
    }

    const elements = [];
    const latestRefs = new Map();
    let truncated = false;
    const visit = root => {
      if (!root || truncated) return;
      for (const child of root.children || []) {
        if (isInteractive(child) && isStyleVisible(child) &&
            (includeOffscreen || isInViewport(child))) {
          if (elements.length >= 200) {
            truncated = true;
            return;
          }
          const ref = refFor(child);
          elements.push(describe(child, ref));
          latestRefs.set(ref, { element: child, fingerprint: fingerprint(child) });
        }
        if (child.shadowRoot && child.shadowRoot.mode === "open") visit(child.shadowRoot);
        visit(child);
        if (truncated) return;
      }
    };
    visit(document);

    state.refs = latestRefs;
    state.revision = resultRevision;
    state.hasSnapshot = true;
    state.snapshotURL = currentDocumentURL();
    return JSON.stringify({
      revision: resultRevision,
      url: bounded(document.location.href, 8192),
      title: bounded(document.title, 2000),
      viewport: viewport(),
      elements,
      truncated
    });
    """#

    private static let actionScript = #"""
    const STATE_KEY = "__passBrowserAutomationState";
    const state = globalThis[STATE_KEY] || (globalThis[STATE_KEY] = {
      nextRef: 1,
      ids: new WeakMap(),
      refs: new Map(),
      knownRefs: new Set(),
      revision: 0,
      hasSnapshot: false,
      snapshotURL: null
    });

    function clean(value) {
      return String(value == null ? "" : value).replace(/\s+/g, " ").trim().slice(0, 500);
    }
    function bounded(value, limit) {
      return String(value == null ? "" : value).slice(0, limit);
    }
    function currentDocumentURL() {
      return String(document.location.href || "");
    }
    function attributeBoolean(el, name) {
      if (!el.hasAttribute(name)) return null;
      return el.getAttribute(name) !== "false";
    }
    function roleOf(el) {
      const explicit = clean(el.getAttribute("role")).toLowerCase().split(" ")[0];
      if (explicit) return explicit;
      const tag = el.localName;
      if (tag === "a" && el.hasAttribute("href")) return "link";
      if (tag === "button") return "button";
      if (tag === "select") return el.multiple ? "listbox" : "combobox";
      if (tag === "textarea") return "textbox";
      if (tag === "summary") return "button";
      if (tag === "option") return "option";
      if (tag === "input") {
        const type = (el.type || "text").toLowerCase();
        if (["button", "submit", "reset", "image"].includes(type)) return "button";
        if (type === "checkbox") return "checkbox";
        if (type === "radio") return "radio";
        if (type === "range") return "slider";
        if (type === "number") return "spinbutton";
        if (type === "search") return "searchbox";
        return "textbox";
      }
      return tag || "element";
    }
    function lookupLabelledBy(el) {
      const ids = clean(el.getAttribute("aria-labelledby")).split(" ").filter(Boolean);
      if (!ids.length) return "";
      const root = el.getRootNode();
      return clean(ids.map(id => {
        const found = typeof root.getElementById === "function"
          ? root.getElementById(id)
          : document.getElementById(id);
        return found?.innerText || found?.textContent || "";
      }).join(" "));
    }
    function nameOf(el) {
      const labelled = lookupLabelledBy(el);
      if (labelled) return labelled;
      const aria = clean(el.getAttribute("aria-label"));
      if (aria) return aria;
      if (el.labels && el.labels.length) {
        const labels = clean(Array.from(el.labels).map(label => label.innerText).join(" "));
        if (labels) return labels;
      }
      const tag = el.localName;
      const type = clean(el.getAttribute("type")).toLowerCase();
      if (tag === "img" || type === "image") {
        const alt = clean(el.getAttribute("alt"));
        if (alt) return alt;
      }
      if (tag === "input" && ["button", "submit", "reset"].includes(type)) {
        const value = clean(el.value);
        if (value) return value;
      }
      const text = clean(el.innerText || el.textContent);
      if (text) return text;
      return clean(
        el.getAttribute("placeholder") ||
        el.getAttribute("title") ||
        el.getAttribute("name") ||
        ""
      );
    }
    function describe(el, ref) {
      const tag = el.localName || "";
      const type = clean(el.getAttribute("type")).toLowerCase();
      const password = tag === "input" && type === "password";
      const result = { ref, role: roleOf(el), name: nameOf(el), tag };
      if (type) result.type = type;
      if (password) {
        result.sensitive = true;
      } else if (tag === "input" || tag === "textarea" || tag === "select") {
        result.value = String(el.value == null ? "" : el.value).slice(0, 2000);
      } else if (el.isContentEditable) {
        result.value = String(el.innerText || el.textContent || "").slice(0, 2000);
      }
      const ariaDisabled = attributeBoolean(el, "aria-disabled");
      if ("disabled" in el || ariaDisabled != null) {
        result.disabled = Boolean(el.disabled) || Boolean(el.matches?.(":disabled")) ||
          ariaDisabled === true;
      }
      const ariaChecked = attributeBoolean(el, "aria-checked");
      if ("checked" in el || ariaChecked != null) {
        result.checked = Boolean(el.checked) || ariaChecked === true;
      }
      const ariaSelected = attributeBoolean(el, "aria-selected");
      if ("selected" in el || ariaSelected != null) {
        result.selected = Boolean(el.selected) || ariaSelected === true;
      }
      const ariaExpanded = attributeBoolean(el, "aria-expanded");
      if (ariaExpanded != null) result.expanded = ariaExpanded;
      return result;
    }
    function fingerprint(el) {
      const form = el.form || null;
      const ariaChecked = attributeBoolean(el, "aria-checked");
      const ariaSelected = attributeBoolean(el, "aria-selected");
      const ariaExpanded = attributeBoolean(el, "aria-expanded");
      const ariaReadonly = attributeBoolean(el, "aria-readonly");
      return JSON.stringify({
        documentURL: bounded(currentDocumentURL(), 8192),
        tag: el.localName || "",
        role: roleOf(el),
        name: nameOf(el),
        type: clean(el.getAttribute("type")).toLowerCase(),
        id: clean(el.id),
        fieldName: clean(el.getAttribute("name")),
        href: bounded(el.href || el.getAttribute("href") || "", 2048),
        rawHref: bounded(el.getAttribute("href") || "", 2048),
        form: form ? {
          id: clean(form.id),
          name: clean(form.getAttribute("name")),
          action: bounded(form.action || form.getAttribute("action") || "", 2048),
          rawAction: bounded(form.getAttribute("action") || "", 2048),
          method: clean(form.method)
        } : null,
        disabled: Boolean(el.disabled) || Boolean(el.matches?.(":disabled")) ||
          attributeBoolean(el, "aria-disabled") === true,
        checked: ("checked" in el) ? Boolean(el.checked) : ariaChecked,
        selected: ("selected" in el) ? Boolean(el.selected) : ariaSelected,
        expanded: ariaExpanded,
        readonly: Boolean(el.readOnly) || el.hasAttribute("readonly") ||
          ariaReadonly === true ||
          (el.hasAttribute("contenteditable") && !el.isContentEditable),
        value: (el.localName === "input" || el.localName === "textarea" ||
                el.localName === "select") ? bounded(el.value, 2000) :
          el.isContentEditable ? bounded(el.textContent, 2000) : null,
        valueTail: (el.localName === "input" || el.localName === "textarea" ||
                    el.localName === "select") ? bounded(String(el.value ?? "").slice(-2000), 2000) :
          el.isContentEditable ? bounded(String(el.textContent ?? "").slice(-2000), 2000) : null,
        valueLength: (el.localName === "input" || el.localName === "textarea" ||
                      el.localName === "select") ? String(el.value ?? "").length :
          el.isContentEditable ? String(el.textContent ?? "").length : null
      });
    }
    function isStyleVisible(el) {
      if (!el.isConnected) return false;
      let current = el;
      while (current && current.nodeType === Node.ELEMENT_NODE) {
        if (current.hidden || current.hasAttribute("inert")) return false;
        const style = getComputedStyle(current);
        if (style.display === "none" || style.visibility === "hidden" ||
            style.visibility === "collapse" || Number(style.opacity) <= 0) return false;
        const root = current.getRootNode();
        current = current.parentElement || root?.host || null;
      }
      return Array.from(el.getClientRects()).some(rect => rect.width > 0 && rect.height > 0);
    }
    function isDisabled(el) {
      return Boolean(el.disabled) || el.matches?.(":disabled") ||
        attributeBoolean(el, "aria-disabled") === true;
    }
    function failure(code, message, extras = {}) {
      return JSON.stringify({ ok: false, error: { code, message, ...extras } });
    }
    function nativeValue(el, value) {
      const tag = el.localName;
      const prototype = tag === "textarea"
        ? HTMLTextAreaElement.prototype
        : tag === "select"
          ? HTMLSelectElement.prototype
          : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
      if (!setter) throw new Error(`no native value setter for ${tag}`);
      setter.call(el, value);
    }
    function isReadOnly(el) {
      return Boolean(el.readOnly) || el.hasAttribute("readonly") ||
        attributeBoolean(el, "aria-readonly") === true ||
        (el.hasAttribute("contenteditable") && !el.isContentEditable);
    }
    function isCharacterEditable(el) {
      if (el.isContentEditable) return true;
      if (el.localName === "textarea") return true;
      if (el.localName !== "input") return false;
      const type = (el.type || "text").toLowerCase();
      return ["text", "search", "url", "tel", "email", "password"].includes(type);
    }
    function placeCaretAtEnd(el, length) {
      const type = (el.type || "text").toLowerCase();
      const supportsSelection = el.localName === "textarea" ||
        (el.localName === "input" &&
         ["text", "search", "url", "tel", "password"].includes(type));
      if (!supportsSelection || typeof el.setSelectionRange !== "function") return;
      try {
        el.setSelectionRange(length, length);
      } catch (_) {
        // Some WebKit input implementations expose setSelectionRange but reject their type.
      }
    }
    function inputEvents(el, includeChange) {
      try {
        el.dispatchEvent(new InputEvent("input", {
          bubbles: true,
          composed: true,
          inputType: "insertText",
          data: null
        }));
      } catch (_) {
        el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
      }
      if (includeChange) {
        el.dispatchEvent(new Event("change", { bubbles: true, composed: true }));
      }
    }
    function deepestElementAt(x, y) {
      let hit = document.elementFromPoint(x, y);
      while (hit?.shadowRoot && hit.shadowRoot.mode === "open") {
        const deeper = hit.shadowRoot.elementFromPoint(x, y);
        if (!deeper || deeper === hit) break;
        hit = deeper;
      }
      return hit;
    }
    function clickablePoint(el) {
      const rects = Array.from(el.getClientRects()).filter(
        rect => rect.width > 0 && rect.height > 0 &&
          rect.right > 0 && rect.bottom > 0 &&
          rect.left < window.innerWidth && rect.top < window.innerHeight
      );
      const rect = rects[0] || el.getBoundingClientRect();
      return {
        x: Math.max(0, Math.min(window.innerWidth - 1, rect.left + rect.width / 2)),
        y: Math.max(0, Math.min(window.innerHeight - 1, rect.top + rect.height / 2))
      };
    }
    function deepestActiveElement() {
      let active = document.activeElement;
      while (active?.shadowRoot?.activeElement) {
        active = active.shadowRoot.activeElement;
      }
      return active;
    }
    function focusNext(el, backwards) {
      const selector = [
        "a[href]", "button:not([disabled])", "input:not([disabled]):not([type=hidden])",
        "select:not([disabled])", "textarea:not([disabled])",
        "[contenteditable=true]", "[tabindex]:not([tabindex='-1'])"
      ].join(",");
      const items = Array.from(document.querySelectorAll(selector)).filter(isStyleVisible);
      const index = items.indexOf(el);
      if (!items.length) return false;
      const delta = backwards ? -1 : 1;
      const start = index >= 0 ? index : (backwards ? 0 : -1);
      const target = items[(start + delta + items.length) % items.length];
      if (!target || target === el) return false;
      target.focus({ preventScroll: true });
      return deepestActiveElement() === target;
    }
    function normalizeKey(value) {
      const raw = String(value == null ? "" : value);
      if (raw === "Space" || raw === "Spacebar") return " ";
      if (raw === "Esc") return "Escape";
      if (raw === "Return") return "Enter";
      return raw;
    }
    function codeForKey(key) {
      if (key === " ") return "Space";
      if (key.length === 1 && /^[a-z]$/i.test(key)) return `Key${key.toUpperCase()}`;
      if (key.length === 1 && /^[0-9]$/.test(key)) return `Digit${key}`;
      return key;
    }
    function isButtonLike(el) {
      const tag = el.localName;
      const type = (el.type || "").toLowerCase();
      return tag === "button" || tag === "summary" ||
        (tag === "input" && ["button", "submit", "reset", "image"].includes(type)) ||
        roleOf(el) === "button";
    }
    function isLinkLike(el) {
      return (el.localName === "a" && el.hasAttribute("href")) || roleOf(el) === "link";
    }
    function isCheckable(el) {
      const type = (el.type || "").toLowerCase();
      const role = roleOf(el);
      return (el.localName === "input" && ["checkbox", "radio"].includes(type)) ||
        ["checkbox", "radio", "switch"].includes(role);
    }
    function isFormEnterTarget(el) {
      if (!el.form || el.localName !== "input") return false;
      const type = (el.type || "text").toLowerCase();
      return !["button", "checkbox", "file", "hidden", "image", "radio",
               "reset", "submit"].includes(type);
    }

    if (!state.hasSnapshot) {
      return failure("snapshot_required", "take a new snapshot before acting");
    }
    if (state.revision !== stateRevision) {
      return failure("stale_revision", "browser state changed", {
        expected: stateRevision,
        actual: state.revision
      });
    }
    if (!state.snapshotURL || state.snapshotURL !== currentDocumentURL()) {
      return failure("snapshot_required", "the page URL changed; take a new snapshot");
    }

    const needsRef = (!["scroll", "press"].includes(actionName)) || hasRef;
    let record = null;
    let recordReference = hasRef ? reference : null;
    let element = null;
    if (needsRef) {
      if (!hasRef) return failure("missing_argument", "ref", { argument: "ref" });
      record = state.refs.get(reference);
      if (!record) {
        const code = state.knownRefs.has(reference) ? "stale_ref" : "unknown_ref";
        return failure(code, "reference is not in the latest snapshot", { ref: reference });
      }
      element = record.element;
      if (!element?.isConnected) {
        return failure("stale_ref", "element was detached", { ref: reference });
      }
      if (record.fingerprint !== fingerprint(element)) {
        return failure("stale_ref", "element fingerprint changed", { ref: reference });
      }
      if (!isStyleVisible(element)) {
        return failure("hidden", "element is not visible", { ref: reference });
      }
      if (isDisabled(element)) {
        return failure("disabled", "element is disabled", { ref: reference });
      }
    } else if (actionName === "press") {
      element = deepestActiveElement();
      if (!element || element.nodeType !== Node.ELEMENT_NODE) {
        element = document.body || document.documentElement;
      }
      if (!element) {
        return failure("invalid_argument", "press has no active document target");
      }
      if (element !== document.body && element !== document.documentElement) {
        for (const [candidateRef, candidateRecord] of state.refs.entries()) {
          if (candidateRecord.element === element) {
            record = candidateRecord;
            recordReference = candidateRef;
            break;
          }
        }
        if (!record) {
          return failure(
            "invalid_argument",
            "active press target is not in the latest browser snapshot"
          );
        }
        if (!element.isConnected || record.fingerprint !== fingerprint(element)) {
          return failure("stale_ref", "active press target changed", {
            ref: recordReference
          });
        }
        if (!isStyleVisible(element)) {
          return failure("hidden", "active press target is not visible", {
            ref: recordReference
          });
        }
      }
    }

    try {
      if (actionName === "click") {
        element.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        if (!isStyleVisible(element)) {
          return failure("hidden", "element is not visible after scrolling", { ref: reference });
        }
        const point = clickablePoint(element);
        const hit = deepestElementAt(point.x, point.y);
        if (!hit || !(hit === element || element.contains(hit))) {
          return failure("covered", "another element covers the target", { ref: reference });
        }
        element.focus({ preventScroll: true });
        element.click();
      } else if (actionName === "fill" || actionName === "type") {
        if (!hasText) {
          return failure("missing_argument", "text", { argument: "text" });
        }
        const tag = element.localName;
        if (isReadOnly(element)) {
          return failure("invalid_argument", `${actionName} target is readonly`);
        }
        if (element.isContentEditable) {
          element.focus({ preventScroll: true });
          if (actionName === "fill") element.textContent = textValue;
          else element.textContent = String(element.textContent || "") + textValue;
          inputEvents(element, actionName === "fill");
        } else if (tag === "input" || tag === "textarea") {
          const type = (element.type || "text").toLowerCase();
          if (["button", "checkbox", "color", "file", "hidden", "image", "radio",
               "range", "reset", "submit"].includes(type)) {
            return failure("invalid_argument", `${actionName} requires a text-editable target`);
          }
          element.focus({ preventScroll: true });
          const next = actionName === "fill"
            ? textValue
            : String(element.value == null ? "" : element.value) + textValue;
          nativeValue(element, next);
          inputEvents(element, actionName === "fill");
          placeCaretAtEnd(element, next.length);
        } else {
          return failure("invalid_argument", `${actionName} requires an input, textarea, or editable target`);
        }
      } else if (actionName === "select") {
        if (!hasText) {
          return failure("missing_argument", "text", { argument: "text" });
        }
        if (element.localName !== "select") {
          return failure("invalid_argument", "select requires a select element");
        }
        const option = Array.from(element.options).find(
          item => item.value === textValue || clean(item.textContent) === clean(textValue)
        );
        if (!option || option.disabled) {
          return failure("invalid_argument", `no enabled option matches ${textValue}`);
        }
        nativeValue(element, option.value);
        inputEvents(element, true);
      } else if (actionName === "press") {
        if (!hasKey || String(keyValue == null ? "" : keyValue).length === 0) {
          return failure("missing_argument", "key", { argument: "key" });
        }
        const key = normalizeKey(keyValue);
        const character = Array.from(key).length === 1;
        let behavior = null;
        if (key === "Tab") {
          behavior = "tab";
        } else if (key === "Escape") {
          behavior = "escape";
        } else if ((key === "Enter" || key === " ") && isButtonLike(element)) {
          behavior = "activate";
        } else if (key === "Enter" && isLinkLike(element)) {
          behavior = "activate";
        } else if (key === " " && isCheckable(element)) {
          behavior = "activate";
        } else if (key === "Enter" && isFormEnterTarget(element)) {
          behavior = "submit";
        } else if (character && isCharacterEditable(element)) {
          behavior = "character";
        }
        if (!behavior) {
          return failure(
            "invalid_argument",
            `key ${key} is not supported for the current press target`
          );
        }
        if (behavior === "character" && isReadOnly(element)) {
          return failure("invalid_argument", "press target is readonly");
        }
        if (isDisabled(element)) {
          return failure("invalid_argument", "press target is disabled");
        }

        if (typeof element.focus === "function") {
          element.focus({ preventScroll: true });
        }
        if ((behavior === "character" || behavior === "escape") &&
            deepestActiveElement() !== element) {
          return failure("invalid_argument", "press target cannot receive keyboard focus");
        }

        const init = {
          key,
          code: codeForKey(key),
          bubbles: true,
          cancelable: true,
          composed: true
        };
        const proceed = element.dispatchEvent(new KeyboardEvent("keydown", init));
        let performed = !proceed;
        if (proceed) {
          if (behavior === "activate") {
            element.click();
            performed = true;
          } else if (behavior === "submit") {
            if (typeof element.form?.requestSubmit !== "function") {
              return failure("invalid_argument", "form submission is unavailable");
            }
            element.form.requestSubmit();
            performed = true;
          } else if (behavior === "tab") {
            performed = focusNext(element, false);
          } else if (behavior === "escape") {
            element.blur();
            performed = deepestActiveElement() !== element;
          } else if (behavior === "character" && element.isContentEditable) {
            element.textContent = String(element.textContent || "") + key;
            inputEvents(element, false);
            performed = true;
          } else if (behavior === "character") {
            const next = String(element.value || "") + key;
            nativeValue(element, next);
            inputEvents(element, false);
            placeCaretAtEnd(element, next.length);
            performed = true;
          }
        }
        element.dispatchEvent(new KeyboardEvent("keyup", init));
        if (!performed) {
          return failure("invalid_argument", `key ${key} had no effect on the press target`);
        }
      } else if (actionName === "scroll") {
        const direction = hasDirection ? clean(directionValue).toLowerCase() : "down";
        if (!["up", "down", "left", "right"].includes(direction)) {
          return failure("invalid_argument", `unknown scroll direction ${direction}`);
        }
        const fallback = direction === "up" || direction === "down"
          ? Math.max(1, window.innerHeight * 0.8)
          : Math.max(1, window.innerWidth * 0.8);
        const amount = hasAmount ? Number(amountValue) : fallback;
        if (!Number.isFinite(amount) || amount <= 0) {
          return failure("invalid_argument", "scroll amount must be a positive number");
        }
        const dx = direction === "left" ? -amount : direction === "right" ? amount : 0;
        const dy = direction === "up" ? -amount : direction === "down" ? amount : 0;
        if (element) {
          element.scrollBy({ left: dx, top: dy, behavior: "instant" });
        } else {
          window.scrollBy({ left: dx, top: dy, behavior: "instant" });
        }
      } else {
        return failure("unsupported_action", actionName);
      }
    } catch (error) {
      return failure("javascript", String(error?.message || error || "action failed"));
    }

    state.revision = resultRevision;
    if (record && element?.isConnected) {
      record.fingerprint = fingerprint(element);
    }
    return JSON.stringify({
      ok: true,
      target: element && hasRef ? describe(element, reference) : null
    });
    """#
}
