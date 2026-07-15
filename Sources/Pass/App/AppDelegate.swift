import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appModel = AppModel()
    private var panelController: PanelController!
    private let notifications = NotificationService()
    private let hookServer = HookServer()
    private var eventRouter: EventRouter?
    private var doubleTapHotkey: DoubleTapHotkey?
    private var shiftTapHotkey: DoubleTapHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always called on the main thread; assert it so we can touch main-actor state.
        MainActor.assumeIsolated { launch() }
    }

    @MainActor
    private func launch() {
        // Accessory app: no Dock icon, no app-switcher entry. (LSUIElement also sets this.)
        NSApp.setActivationPolicy(.accessory)

        // A minimal main menu so standard editing shortcuts (⌘X/C/V/A/Z) work inside the
        // panel's text fields even though we have no visible menu bar (FINDINGS/plan R5).
        NSApp.mainMenu = Self.makeMainMenu()

        // Build stores + start the reconcile loop.
        appModel.configure()
        let notifications = self.notifications
        appModel.clearSessionNotifications = { name in
            notifications.clear(session: name, kinds: [
                Attention.Kind.decision.rawValue, Attention.Kind.input.rawValue, Attention.Kind.finished.rawValue,
            ])
        }

        // Panel (non-activating, keyboard-first).
        panelController = PanelController(appModel: appModel)
        appModel.panelController = panelController

        // Global hotkeys → toggle the panel: ⌘⌘ double-tap (primary) + ⌥Space (rebindable).
        HotkeyService.registerSummon { [weak self] in
            self?.panelController.toggle()
        }
        doubleTapHotkey = DoubleTapHotkey { [weak self] in
            self?.panelController.toggle()
        }
        // ⇧⇧ hops to the next session waiting for input — only while the panel has the
        // keyboard, so shift taps in other apps never move pass's selection.
        shiftTapHotkey = DoubleTapHotkey(modifier: .shift) { [weak self] in
            guard let self, self.panelController.isKey else { return }
            _ = self.appModel.keyHandler?(PanelNavEvent(key: .nextWaiting, command: false, option: false))
        }

        // Notifications.
        UNUserNotificationCenter.current().delegate = self
        Task { [appModel, notifications] in
            let status = await notifications.requestAuthorization()
            await MainActor.run { appModel.notificationsBlocked = (status == .denied) }
        }

        // Hooks: detect install state; offer one-click install (don't clobber the user's file).
        appModel.needsHookInstall = !ClaudeHooksInstaller.isInstalled()
        if ProcessInfo.processInfo.environment["PASS_DEBUG_INSTALL_HOOKS"] == "1" {
            appModel.installHooks()
        }

        // passcli: keep the stable symlink (~/.pass/bin/passcli) pointing at THIS bundle's
        // helper — sessions and the advertise hook reference the symlink, so the app can move
        // (or run from a build dir) without breaking them.
        CLIInstaller.refreshSymlink()

        // Hook server + event routing.
        startHookPipeline()

        if let p = ProcessInfo.processInfo.environment["PASS_DEBUG_ADD_PROJECTS"], !p.isEmpty {
            appModel.addProjects(dirs: p.components(separatedBy: ":"))
        }
        if let s = ProcessInfo.processInfo.environment["PASS_DEBUG_OPEN"], !s.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [appModel, panelController] in
                panelController?.show(preselecting: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { appModel.forceOpenSession = s }
            }
        }
        // PASS_DEBUG_SPECS=<project root> — open the panel straight onto the specs screen
        // (SpecsView preselects the given root). Headless verification of the spec document UI.
        if let root = ProcessInfo.processInfo.environment["PASS_DEBUG_SPECS"], !root.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [appModel] in
                appModel.showSpecs()
            }
        }
        // PASS_DEBUG_BROWSER=<session>|<url> — drive the CLI open path on launch (headless
        // verification of the workspace split without needing passcli).
        if let spec = ProcessInfo.processInfo.environment["PASS_DEBUG_BROWSER"],
           let bar = spec.firstIndex(of: "|") {
            let session = String(spec[..<bar])
            let raw = String(spec[spec.index(after: bar)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [appModel] in
                guard case .success(let url) = URLNormalizer.normalize(raw) else { return }
                appModel.openBrowserFromCLI(session: session, url: url, background: false)
            }
        }

        appModel.isReady = true
        Log.app.info("pass launched (accessory, hook port \(PassConfig.hookPort))")
    }

    @MainActor
    private func startHookPipeline() {
        let notifications = self.notifications
        let router = EventRouter(
            sessions: appModel.sessions,
            onAttention: { name, display, att in
                let sound = att.kind != .finished // finished notifies silently
                let body: String
                switch att.kind {
                case .decision: body = "Permission needed — \(att.preview)"
                case .input:    body = att.preview
                case .finished: body = att.preview
                }
                Task { await notifications.notify(session: name, kind: att.kind.rawValue,
                                                  title: display, body: body, sound: sound) }
            },
            onResolved: { name in
                notifications.clear(session: name, kinds: [
                    Attention.Kind.decision.rawValue,
                    Attention.Kind.input.rawValue,
                    Attention.Kind.finished.rawValue,
                ])
            }
        )
        self.eventRouter = router

        Task { @MainActor in
            let appModel = self.appModel
            let share = ShareHandlers(
                targets: { await MainActor.run { ShareAPI.targets(appModel) } },
                send: { body in await ShareAPI.send(appModel, body: body) }
            )
            let cli = CLIHandlers(
                open: { body in await CLIAPI.open(appModel, body: body) },
                close: { body in await MainActor.run { CLIAPI.close(appModel, body: body) } },
                tabs: { await MainActor.run { CLIAPI.tabs(appModel) } },
                screenshot: { body in await CLIAPI.screenshot(appModel, body: body) },
                read: { body in await CLIAPI.read(appModel, body: body) }
            )
            await hookServer.start(port: PassConfig.hookPort, share: share, cli: cli)
            appModel.hookServerFailed = !(await hookServer.didBind)
            for await hit in hookServer.events {
                router.route(path: hit.path, raw: hit.raw)
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show notifications even while pass is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a notification summons the panel (M3 will deep-link to the session).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let sessionName = response.notification.request.content.userInfo["session"] as? String
        Log.app.debug("notification clicked, session=\(sessionName ?? "-", privacy: .public)")
        await MainActor.run {
            panelController.show(preselecting: sessionName)
        }
    }

    // MARK: Main menu

    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // App menu (Quit).
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit pass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — enables ⌘X/C/V/A/Z in text fields for an accessory app.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return main
    }
}
