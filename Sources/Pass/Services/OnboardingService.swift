import AppKit
import Foundation
import Observation

enum OnboardingPreference {
    static let completedKey = "onboarding.completed.v1"
}

struct OnboardingDependency: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case tmux
        case git
        case claude
        case codex
        case pi
    }

    let kind: Kind
    let name: String
    let purpose: String
    let isRequired: Bool
    var path: String?
    var version: String?

    var id: Kind { kind }
    var isInstalled: Bool { path != nil }
}

enum OnboardingDiagnostics {
    static func scan() -> [OnboardingDependency] {
        [
            dependency(.tmux, name: "tmux",
                       purpose: "Keeps sessions alive after Pass closes and powers terminal access.",
                       required: true, versionArgs: ["-V"]),
            dependency(.git, name: "Git",
                       purpose: "Identifies projects, branches, and worktrees.",
                       required: false, versionArgs: ["--version"]),
            dependency(.claude, name: "Claude Code",
                       purpose: "Runs Claude sessions and reports when they need you.",
                       required: false, versionArgs: ["--version"]),
            dependency(.codex, name: "Codex",
                       purpose: "Runs Codex CLI sessions from Pass.",
                       required: false, versionArgs: ["--version"]),
            dependency(.pi, name: "pi",
                       purpose: "Runs pi coding-agent sessions from Pass.",
                       required: false, versionArgs: ["--version"]),
        ]
    }

    static func homebrewPath() -> String? {
        Shell.resolveViaLoginShell("brew")
    }

    private static func dependency(
        _ kind: OnboardingDependency.Kind,
        name: String,
        purpose: String,
        required: Bool,
        versionArgs: [String]
    ) -> OnboardingDependency {
        guard let path = Shell.resolveViaLoginShell(kind.rawValue) else {
            return OnboardingDependency(kind: kind, name: name, purpose: purpose,
                                          isRequired: required)
        }
        let result = Shell.run(path, versionArgs)
        let firstLine = (result.stdout.isEmpty ? result.stderr : result.stdout)
            .split(separator: "\n").first.map(String.init)
        return OnboardingDependency(kind: kind, name: name, purpose: purpose,
                                      isRequired: required, path: path, version: firstLine)
    }
}

@MainActor
@Observable
final class OnboardingModel {
    enum InstallState: Equatable {
        case idle
        case installing
        case failed(String)
    }

    var step = 0
    var dependencies: [OnboardingDependency] = []
    var isScanning = false
    var installState: InstallState = .idle
    var installedHooks: [AgentKind: Bool] = [:]
    var integrationError: String?
    var cliLinked = false
    var homebrewPath: String?

    private let appModel: AppModel
    private let close: () -> Void

    init(appModel: AppModel, close: @escaping () -> Void) {
        self.appModel = appModel
        self.close = close
    }

    var tmux: OnboardingDependency? {
        dependencies.first { $0.kind == .tmux }
    }

    var canContinueFromCheck: Bool {
        tmux?.isInstalled == true && installState != .installing
    }

    var installedAgentCount: Int {
        dependencies.filter {
            [.claude, .codex, .pi].contains($0.kind) && $0.isInstalled
        }.count
    }

    var projectDirectories: [String] {
        appModel.projects?.projectDirectories ?? []
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        installState = .idle
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                (OnboardingDiagnostics.scan(), OnboardingDiagnostics.homebrewPath())
            }.value
            dependencies = result.0
            homebrewPath = result.1
            refreshHookStatus()
            cliLinked = CLIInstaller.isLinked
            isScanning = false
        }
    }

    /// Start the walkthrough from the beginning while preserving the machine's real setup.
    /// Diagnostics run again so this is useful after installing or removing a dependency.
    func restart() {
        step = 0
        installState = .idle
        scan()
    }

    func installTmux() {
        guard let homebrewPath else {
            open(URL(string: "https://brew.sh")!)
            return
        }
        installState = .installing
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Shell.run(homebrewPath, ["install", "tmux"])
            }.value
            if result.ok {
                await appModel.refreshRuntimeAvailability()
                scan()
            } else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                installState = .failed(detail.isEmpty ? "Could not install tmux." : detail)
            }
        }
    }

    func hooksInstalled(for agent: AgentKind) -> Bool {
        installedHooks[agent] == true
    }

    func installHooks(for agent: AgentKind) {
        integrationError = nil
        let status = AgentHooksInstaller.install(for: agent)
        refreshHookStatus()
        appModel.needsHookInstall = !AgentHooksInstaller.isInstalled()
        if case .failed(let message) = status {
            integrationError = "Could not install \(agent.rawValue) hooks: \(message)"
        }
    }

    func linkCLI() {
        CLIInstaller.refreshSymlink()
        cliLinked = CLIInstaller.isLinked
    }

    func chooseProjectDirectories() {
        let directories = ProjectPicker.pick()
        guard !directories.isEmpty else { return }
        appModel.addProjects(dirs: directories)
    }

    func removeProjectDirectory(_ path: String) {
        appModel.projects?.forgetDirectory(path: path)
    }

    func openGuide(for kind: OnboardingDependency.Kind) {
        let rawURL: String
        switch kind {
        case .tmux: rawURL = "https://brew.sh"
        case .git: rawURL = "https://git-scm.com/download/mac"
        case .claude:
            rawURL = "https://docs.anthropic.com/en/docs/claude-code/getting-started"
        case .codex:
            rawURL = "https://help.openai.com/en/articles/11096431"
        case .pi:
            rawURL = "https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/README.md"
        }
        guard let url = URL(string: rawURL) else { return }
        open(url)
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: OnboardingPreference.completedKey)
        close()
        appModel.summon()
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func refreshHookStatus() {
        installedHooks = Dictionary(uniqueKeysWithValues: AgentKind.launchable.map {
            ($0, AgentHooksInstaller.isInstalled(for: $0))
        })
    }
}
