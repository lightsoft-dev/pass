import AppKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    // App-icon palette: electric violet on a soft acid-yellow field.
    private let ink = Color(red: 0.055, green: 0.050, blue: 0.075)
    private let paper = Color(red: 0.95, green: 0.94, blue: 0.87)
    private let violet = Color(red: 0.41, green: 0.27, blue: 0.91)
    private let signal = Color(red: 0.96, green: 0.93, blue: 0.38)
    private let lavender = Color(red: 0.57, green: 0.49, blue: 0.91)

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            RadialGradient(
                colors: [violet.opacity(0.20), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 520
            )
            .ignoresSafeArea()
            scanLines
            HStack(spacing: 0) {
                flightRail
                Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
                content
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if model.dependencies.isEmpty { model.scan() }
        }
    }

    private var scanLines: some View {
        Canvas { context, size in
            for y in stride(from: 0.0, through: size.height, by: 5) {
                context.stroke(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                    with: .color(.white.opacity(0.018))
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var flightRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("PASS")
                    .font(.custom("Avenir Next", size: 14).weight(.heavy))
                    .tracking(2.8)
            }
            .padding(.bottom, 48)

            ForEach(0..<3, id: \.self) { index in
                railItem(index)
                if index < 2 {
                    Rectangle()
                        .fill(index < model.step ? lavender.opacity(0.8) : Color.white.opacity(0.13))
                        .frame(width: 1, height: 54)
                        .padding(.leading, 12)
                }
            }
            Spacer()
            Text("LOCAL MISSION CONTROL")
                .font(.custom("Menlo", size: 9))
                .tracking(1.4)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 205, alignment: .leading)
    }

    private func railItem(_ index: Int) -> some View {
        let labels = ["Welcome", "Pre-flight check", "Connect agents"]
        let active = index == model.step
        let complete = index < model.step
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(active ? signal : (complete ? lavender : Color.white.opacity(0.10)))
                if complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(ink)
                } else {
                    Text("0\(index + 1)")
                        .font(.custom("Menlo", size: 8))
                        .foregroundStyle(active ? ink : .secondary)
                }
            }
            .frame(width: 25, height: 25)
            Text(labels[index])
                .font(.custom("Avenir Next", size: 12).weight(active ? .bold : .medium))
                .foregroundStyle(active ? paper : .secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.step {
            case 0: welcome
            case 1: systemCheck
            default: integrations
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 42)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("MISSION BRIEF")
            Text("Every coding agent.\nOne mission control.")
                .font(.custom("Avenir Next", size: 39).weight(.heavy))
                .foregroundStyle(paper)
                .lineSpacing(-2)
                .padding(.top, 14)
            Text("Pass runs coding agents on tmux. Their work continues when the app closes, and only surfaces when a response or approval needs you.")
                .font(.custom("Avenir Next", size: 15))
                .foregroundStyle(paper.opacity(0.72))
                .lineSpacing(5)
                .frame(maxWidth: 470, alignment: .leading)
                .padding(.top, 22)

            HStack(spacing: 0) {
                metric("⌥ SPACE", "Open anywhere")
                divider
                metric("tmux", "Persistent sessions")
                divider
                metric("LOCAL", "Runs on your Mac")
            }
            .padding(.top, 42)

            Spacer()
            HStack {
                Text("About 2 minutes · Your existing settings stay intact")
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                primaryButton("Get started", icon: "arrow.right") { model.step = 1 }
            }
        }
    }

    private var systemCheck: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 8) {
                    eyebrow("PRE-FLIGHT  /  REQUIRED")
                    Text("Check the essentials")
                        .font(.custom("Avenir Next", size: 28).weight(.heavy))
                        .foregroundStyle(paper)
                }
                Spacer()
                Button { model.scan() } label: {
                    Label("Scan again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.custom("Avenir Next", size: 12).weight(.semibold))
                .foregroundStyle(.secondary)
                .disabled(model.isScanning)
            }

            VStack(spacing: 10) {
                dependencyRow(.tmux)
                dependencyRow(.git)
            }
            .padding(.top, 28)

            if case .failed(let message) = model.installState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.top, 14)
            } else if model.tmux?.isInstalled == false {
                Text(model.homebrewPath == nil
                     ? "Homebrew is not available. Install it, then choose “Scan again.”"
                     : "Pass can install tmux with Homebrew. No administrator password is requested.")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
            }

            Spacer()
            HStack {
                Button("Back") { model.step = 0 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.tmux?.isInstalled == false {
                    primaryButton(
                        model.homebrewPath == nil ? "Open Homebrew guide" : "Install tmux",
                        icon: model.installState == .installing ? nil : "arrow.down.circle"
                    ) {
                        model.installTmux()
                    }
                    .disabled(model.installState == .installing)
                } else {
                    primaryButton("Continue", icon: "arrow.right") { model.step = 2 }
                        .disabled(!model.canContinueFromCheck)
                }
            }
        }
    }

    private var integrations: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("CONNECT  /  CHOOSE YOUR CREW")
            Text("Connect your agents")
                .font(.custom("Avenir Next", size: 28).weight(.heavy))
                .foregroundStyle(paper)
                .padding(.top, 8)
            Text("One is enough to begin. You can add the others later in Settings.")
                .font(.custom("Avenir Next", size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 7)

            HStack(spacing: 10) {
                agentCard(.claude, glyph: "✳")
                agentCard(.codex, glyph: "⬢")
                agentCard(.pi, glyph: "π")
            }
            .padding(.top, 24)

            VStack(spacing: 0) {
                agentHookRow(
                    .claude,
                    title: "Claude Code hooks",
                    detail: "Approvals, questions, and completion events"
                )
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                agentHookRow(
                    .codex,
                    title: "Codex hooks",
                    detail: "Lifecycle events · review once with /hooks"
                )
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                agentHookRow(
                    .pi,
                    title: "pi extension",
                    detail: "Prompt, completion, and session events"
                )
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                integrationRow(
                    title: "passcli",
                    detail: "Lets agents control Pass browser tabs and sessions",
                    ready: model.cliLinked,
                    action: model.linkCLI
                )
            }
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.10)))
            .padding(.top, 18)

            if let error = model.integrationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.custom("Menlo", size: 9))
                    .foregroundStyle(signal)
                    .lineLimit(2)
                    .padding(.top, 10)
            }

            Spacer()
            HStack {
                Button("Back") { model.step = 1 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.installedAgentCount == 0 {
                    Text("You can install an agent CLI later")
                        .font(.custom("Menlo", size: 9))
                        .foregroundStyle(.tertiary)
                }
                primaryButton("Open Pass", icon: "arrow.up.right") { model.finish() }
            }
        }
    }

    private func dependencyRow(_ kind: OnboardingDependency.Kind) -> some View {
        let dependency = model.dependencies.first { $0.kind == kind }
        let installed = dependency?.isInstalled == true
        let isTmux = kind == .tmux
        return HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(installed ? lavender.opacity(0.13) : signal.opacity(0.13))
                Image(systemName: installed ? "checkmark" : "exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(installed ? lavender : signal)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(dependency?.name ?? kind.rawValue)
                        .font(.custom("Avenir Next", size: 14).weight(.bold))
                        .foregroundStyle(paper)
                    Text(isTmux ? "REQUIRED" : "RECOMMENDED")
                        .font(.custom("Menlo", size: 8))
                        .foregroundStyle(isTmux ? signal : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                Text(dependency?.purpose ?? "Checking…")
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(installed ? "READY" : "MISSING")
                        .font(.custom("Menlo", size: 9).weight(.bold))
                        .foregroundStyle(installed ? lavender : signal)
                    if let version = dependency?.version {
                        Text(version)
                            .font(.custom("Menlo", size: 8))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(maxWidth: 150, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.10)))
    }

    private func agentCard(_ kind: OnboardingDependency.Kind, glyph: String) -> some View {
        let dependency = model.dependencies.first { $0.kind == kind }
        let installed = dependency?.isInstalled == true
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(glyph)
                    .font(.custom("Avenir Next", size: 20).weight(.bold))
                    .foregroundStyle(installed ? lavender : paper)
                Spacer()
                Circle().fill(installed ? lavender : signal).frame(width: 7, height: 7)
            }
            Text(dependency?.name ?? kind.rawValue)
                .font(.custom("Avenir Next", size: 13).weight(.bold))
                .foregroundStyle(paper)
            if installed {
                Text("INSTALLED")
                    .font(.custom("Menlo", size: 9))
                    .foregroundStyle(lavender)
            } else {
                Button("INSTALL GUIDE ↗") { model.openGuide(for: kind) }
                    .buttonStyle(.plain)
                    .font(.custom("Menlo", size: 9))
                    .foregroundStyle(signal)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(installed ? lavender.opacity(0.45) : Color.white.opacity(0.10)))
    }

    private func agentHookRow(
        _ agent: AgentKind,
        title: String,
        detail: String
    ) -> some View {
        integrationRow(
            title: title,
            detail: detail,
            ready: model.hooksInstalled(for: agent)
        ) {
            model.installHooks(for: agent)
        }
    }

    private func integrationRow(
        title: String,
        detail: String,
        ready: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.seal.fill" : "circle.dashed")
                .foregroundStyle(ready ? lavender : signal)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.custom("Avenir Next", size: 12).weight(.bold))
                    .foregroundStyle(paper)
                Text(detail)
                    .font(.custom("Avenir Next", size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(ready ? "DONE" : "SET UP") { action() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(ready)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.custom("Menlo", size: 9).weight(.bold))
            .tracking(1.6)
            .foregroundStyle(signal)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.custom("Menlo", size: 13).weight(.bold))
                .foregroundStyle(signal)
            Text(label)
                .font(.custom("Avenir Next", size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 37)
    }

    private func primaryButton(
        _ title: String,
        icon: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if model.installState == .installing && title == "Install tmux" {
                    ProgressView().controlSize(.small)
                }
                Text(title)
                if let icon { Image(systemName: icon) }
            }
            .font(.custom("Avenir Next", size: 13).weight(.bold))
            .foregroundStyle(ink)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(signal, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
