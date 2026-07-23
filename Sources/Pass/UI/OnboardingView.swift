import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    private let ink = Color(red: 0.07, green: 0.08, blue: 0.08)
    private let paper = Color(red: 0.93, green: 0.91, blue: 0.85)
    private let amber = Color(red: 0.93, green: 0.63, blue: 0.18)
    private let mint = Color(red: 0.40, green: 0.86, blue: 0.64)

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
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
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(amber)
                    Text("P")
                        .font(.custom("Avenir Next", size: 17).weight(.heavy))
                        .foregroundStyle(ink)
                }
                .frame(width: 31, height: 31)
                Text("PASS")
                    .font(.custom("Avenir Next", size: 14).weight(.heavy))
                    .tracking(2.8)
            }
            .padding(.bottom, 48)

            ForEach(0..<3, id: \.self) { index in
                railItem(index)
                if index < 2 {
                    Rectangle()
                        .fill(index < model.step ? mint.opacity(0.7) : Color.white.opacity(0.13))
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
        let labels = ["어서 오세요", "비행 전 점검", "에이전트 연결"]
        let active = index == model.step
        let complete = index < model.step
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(active ? amber : (complete ? mint : Color.white.opacity(0.10)))
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
            Text("여러 에이전트를,\n한 곳에서.")
                .font(.custom("Avenir Next", size: 39).weight(.heavy))
                .foregroundStyle(paper)
                .lineSpacing(-2)
                .padding(.top, 14)
            Text("Pass는 tmux 위에서 코딩 에이전트를 실행합니다. 앱을 닫아도 작업은 계속되고, 답변이나 승인이 필요할 때만 앞으로 가져옵니다.")
                .font(.custom("Avenir Next", size: 15))
                .foregroundStyle(paper.opacity(0.72))
                .lineSpacing(5)
                .frame(maxWidth: 470, alignment: .leading)
                .padding(.top, 22)

            HStack(spacing: 0) {
                metric("⌥ SPACE", "어디서든 열기")
                divider
                metric("tmux", "세션 유지")
                divider
                metric("LOCAL", "내 Mac에서 실행")
            }
            .padding(.top, 42)

            Spacer()
            HStack {
                Text("약 2분 · 기존 설정을 덮어쓰지 않습니다")
                    .font(.custom("Menlo", size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                primaryButton("시작하기", icon: "arrow.right") { model.step = 1 }
            }
        }
    }

    private var systemCheck: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 8) {
                    eyebrow("PRE-FLIGHT  /  REQUIRED")
                    Text("기본 런타임 점검")
                        .font(.custom("Avenir Next", size: 28).weight(.heavy))
                        .foregroundStyle(paper)
                }
                Spacer()
                Button { model.scan() } label: {
                    Label("다시 점검", systemImage: "arrow.clockwise")
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
                     ? "Homebrew가 없어 설치 안내를 엽니다. Homebrew 설치 후 ‘다시 점검’을 눌러주세요."
                     : "Pass가 Homebrew로 tmux를 설치할 수 있습니다. 관리자 암호는 요청하지 않습니다.")
                    .font(.custom("Avenir Next", size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
            }

            Spacer()
            HStack {
                Button("이전") { model.step = 0 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.tmux?.isInstalled == false {
                    primaryButton(
                        model.homebrewPath == nil ? "Homebrew 설치 안내" : "tmux 설치",
                        icon: model.installState == .installing ? nil : "arrow.down.circle"
                    ) {
                        model.installTmux()
                    }
                    .disabled(model.installState == .installing)
                } else {
                    primaryButton("계속", icon: "arrow.right") { model.step = 2 }
                        .disabled(!model.canContinueFromCheck)
                }
            }
        }
    }

    private var integrations: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("CONNECT  /  CHOOSE YOUR CREW")
            Text("사용할 에이전트 연결")
                .font(.custom("Avenir Next", size: 28).weight(.heavy))
                .foregroundStyle(paper)
                .padding(.top, 8)
            Text("하나만 있어도 충분합니다. 나머지는 언제든 설정에서 추가할 수 있습니다.")
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
                integrationRow(
                    title: "Claude Code hooks",
                    detail: "승인·질문·완료 이벤트를 로컬 Pass로 전달",
                    ready: model.hooksInstalled,
                    action: model.installHooks
                )
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                integrationRow(
                    title: "passcli",
                    detail: "에이전트가 Pass의 브라우저와 세션을 제어",
                    ready: model.cliLinked,
                    action: model.linkCLI
                )
            }
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.10)))
            .padding(.top, 18)

            Spacer()
            HStack {
                Button("이전") { model.step = 1 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.installedAgentCount == 0 {
                    Text("에이전트 CLI는 나중에 설치해도 됩니다")
                        .font(.custom("Menlo", size: 9))
                        .foregroundStyle(.tertiary)
                }
                primaryButton("Pass 열기", icon: "arrow.up.right") { model.finish() }
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
                    .fill(installed ? mint.opacity(0.13) : amber.opacity(0.13))
                Image(systemName: installed ? "checkmark" : "exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(installed ? mint : amber)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(dependency?.name ?? kind.rawValue)
                        .font(.custom("Avenir Next", size: 14).weight(.bold))
                        .foregroundStyle(paper)
                    Text(isTmux ? "필수" : "권장")
                        .font(.custom("Menlo", size: 8))
                        .foregroundStyle(isTmux ? amber : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                Text(dependency?.purpose ?? "확인 중…")
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
                        .foregroundStyle(installed ? mint : amber)
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
                    .foregroundStyle(installed ? mint : paper)
                Spacer()
                Circle().fill(installed ? mint : amber).frame(width: 7, height: 7)
            }
            Text(dependency?.name ?? kind.rawValue)
                .font(.custom("Avenir Next", size: 13).weight(.bold))
                .foregroundStyle(paper)
            if installed {
                Text("설치됨")
                    .font(.custom("Menlo", size: 9))
                    .foregroundStyle(mint)
            } else {
                Button("설치 안내 ↗") { model.openGuide(for: kind) }
                    .buttonStyle(.plain)
                    .font(.custom("Menlo", size: 9))
                    .foregroundStyle(amber)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(installed ? mint.opacity(0.35) : Color.white.opacity(0.10)))
    }

    private func integrationRow(
        title: String,
        detail: String,
        ready: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.seal.fill" : "circle.dashed")
                .foregroundStyle(ready ? mint : amber)
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
            Button(ready ? "완료" : "설정") { action() }
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
            .foregroundStyle(amber)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.custom("Menlo", size: 13).weight(.bold))
                .foregroundStyle(amber)
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
                if model.installState == .installing && title == "tmux 설치" {
                    ProgressView().controlSize(.small)
                }
                Text(title)
                if let icon { Image(systemName: icon) }
            }
            .font(.custom("Avenir Next", size: 13).weight(.bold))
            .foregroundStyle(ink)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(amber, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
