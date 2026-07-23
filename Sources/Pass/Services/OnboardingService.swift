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
                       purpose: "세션을 앱 종료 뒤에도 살려두고 터미널을 연결합니다.",
                       required: true, versionArgs: ["-V"]),
            dependency(.git, name: "Git",
                       purpose: "프로젝트, 브랜치와 worktree를 식별합니다.",
                       required: false, versionArgs: ["--version"]),
            dependency(.claude, name: "Claude Code",
                       purpose: "Claude 세션을 시작하고 필요한 순간을 Pass에 알립니다.",
                       required: false, versionArgs: ["--version"]),
            dependency(.codex, name: "Codex",
                       purpose: "Codex CLI 세션을 Pass에서 시작합니다.",
                       required: false, versionArgs: ["--version"]),
            dependency(.pi, name: "pi",
                       purpose: "pi coding agent 세션을 Pass에서 시작합니다.",
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
    var hooksInstalled = false
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
            hooksInstalled = ClaudeHooksInstaller.isInstalled()
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
                installState = .failed(detail.isEmpty ? "tmux 설치에 실패했습니다." : detail)
            }
        }
    }

    func installHooks() {
        appModel.installHooks()
        hooksInstalled = ClaudeHooksInstaller.isInstalled()
    }

    func linkCLI() {
        CLIInstaller.refreshSymlink()
        cliLinked = CLIInstaller.isLinked
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
}
