import AppKit
import Sparkle
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
    private var onboardingController: OnboardingWindowController?
    /// Retaining the standard controller starts Sparkle's scheduled checks and owns its UI.
    private lazy var updaterController = SPUStandardUpdaterController(
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always called on the main thread; assert it so we can touch main-actor state.
        MainActor.assumeIsolated { launch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            doubleTapHotkey?.invalidate()
            shiftTapHotkey?.invalidate()
            appModel.stopProjectDirectorySync()
            appModel.mirror?.shutdown()
            appModel.miniTerminals?.closeAll()
            appModel.sessions?.flushSave()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            appModel.scheduleProjectDirectorySyncForVisibilityChange()
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            appModel.scheduleProjectDirectorySyncForVisibilityChange()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            if onboardingController?.window?.isVisible == true {
                onboardingController?.show()
            } else {
                panelController?.show(preselecting: nil)
            }
        }
        return true
    }

    @MainActor
    private func launch() {
        // LSUIElement prevents a launch-time Dock flash. The user's onboarding choice then
        // decides whether Pass remains an accessory or joins the Dock and app switcher.
        let appPresence = OnboardingPreference.appPresence()
        NSApp.setActivationPolicy(appPresence.activationPolicy)

        // A minimal main menu so standard editing shortcuts (⌘X/C/V/A/Z) work inside the
        // panel's text fields even though we have no visible menu bar (FINDINGS/plan R5).
        appModel.checkForAppUpdateHandler = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
        NSApp.mainMenu = makeMainMenu()
#if DEBUG
        if ProcessInfo.processInfo.environment["PASS_DEBUG_CHECK_FOR_UPDATES"] == "1" {
            DispatchQueue.main.async { [weak self] in
                self?.updaterController.checkForUpdates(nil)
            }
        }
#endif

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
        let onboardingController = OnboardingWindowController(appModel: appModel)
        self.onboardingController = onboardingController
        appModel.showOnboardingHandler = { [weak onboardingController] in
            onboardingController?.show()
        }

        // Global summon hotkey: Settings chooses exactly one of ⌘⌘ or ⌥Space.
        HotkeyService.registerSummon { [weak self] in
            self?.panelController.toggle()
        }
        appModel.summonShortcutModeChanged = { [weak self] mode in
            self?.applySummonShortcutMode(mode)
        }
        applySummonShortcutMode(.current)
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
        appModel.needsHookInstall = !AgentHooksInstaller.isInstalled()
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
        let completedOnboarding = UserDefaults.standard.bool(
            forKey: OnboardingPreference.completedKey
        )
        if !completedOnboarding || Shell.resolveViaLoginShell("tmux") == nil {
            DispatchQueue.main.async { onboardingController.show() }
        }
        Log.app.info("pass launched (\(appPresence.rawValue, privacy: .public), hook port \(PassConfig.hookPort))")
    }

    @MainActor
    private func applySummonShortcutMode(_ mode: SummonShortcutMode) {
        switch mode {
        case .doubleCommand:
            HotkeyService.setOptionSpaceEnabled(false)
            if doubleTapHotkey == nil {
                doubleTapHotkey = DoubleTapHotkey { [weak self] in
                    self?.panelController.toggle()
                }
            }
        case .optionSpace:
            doubleTapHotkey?.invalidate()
            doubleTapHotkey = nil
            HotkeyService.setOptionSpaceEnabled(true)
        }
        Log.app.info("summon shortcut selected (\(mode.rawValue))")
    }

    @MainActor
    private func startHookPipeline() {
        let notifications = self.notifications
        let appModel = self.appModel
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
                appModel.extensionBuilder?.attentionPending(sessionName: name, attention: att)
                if appModel.sessions?.isEphemeral(name) != true,
                   appModel.extensionBuilder?.ownsSession(name) != true {
                    appModel.extensionRuntime?.attentionPending(sessionName: name, attention: att)
                }
            },
            onResolved: { name in
                notifications.clear(session: name, kinds: [
                    Attention.Kind.decision.rawValue,
                    Attention.Kind.input.rawValue,
                    Attention.Kind.finished.rawValue,
                ])
                if appModel.sessions?.isEphemeral(name) != true,
                   appModel.extensionBuilder?.ownsSession(name) != true {
                    appModel.extensionRuntime?.attentionResolved(sessionName: name)
                }
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
                read: { body in await CLIAPI.read(appModel, body: body) },
                snapshot: { body in await CLIAPI.snapshot(appModel, body: body) },
                action: { body in await CLIAPI.action(appModel, body: body) },
                validateExtension: { body in await MainActor.run {
                    CLIAPI.validateExtension(body: body)
                } },
                configURLAdd: { body in await MainActor.run { CLIAPI.addConfigURL(appModel, body: body) } }
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

    /// Clicking a notification summons the panel and selects the session that emitted it.
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
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // App menu (Quit).
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
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

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
}
