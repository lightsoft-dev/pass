import AppKit
import SwiftUI

/// Content of the device-mirror panel: a window picker until a source is chosen, then the
/// live mirror with a small overlay toolbar (back to the picker / keep-on-top).
struct MirrorView: View {
    let engine: MirrorEngine
    let onToggleFloat: () -> Void

    // Shared with MirrorWindowController, which applies the actual window level.
    @AppStorage("mirror.floating") private var floats = true
    @State private var hoveringControls = false

    var body: some View {
        switch engine.state {
        case .pickingSource:
            picker
        case .streaming:
            live
        case .failed(let message):
            failed(message)
        }
    }

    // MARK: Source picker

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "iphone").foregroundStyle(.secondary)
                Text("Mirror a device window").font(.system(size: 13, weight: .semibold))
                Spacer()
                if engine.isRefreshing { ProgressView().controlSize(.small) }
                Button {
                    Task { await engine.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh window list")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            if engine.permissionDenied {
                permissionHelp
            } else if engine.sources.isEmpty && !engine.isRefreshing {
                emptyHelp
            } else {
                sourceList
            }

            Divider()
            Text("Real device? Mirror an iPhone with QuickTime (File → New Movie Recording) or an Android device with scrcpy, then pick that window here.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .task { await engine.refreshSources() }
    }

    private var sourceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                let devices = engine.sources.filter(\.isDeviceLike)
                let others = engine.sources.filter { !$0.isDeviceLike }
                if !devices.isEmpty {
                    sectionHeader("Device windows")
                    ForEach(devices) { sourceRow($0) }
                }
                if !others.isEmpty {
                    sectionHeader(devices.isEmpty ? "Windows" : "Other windows")
                    ForEach(others) { sourceRow($0) }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
    }

    private func sourceRow(_ source: MirrorSource) -> some View {
        Button {
            Task { await engine.start(source) }
        } label: {
            HStack(spacing: 8) {
                if let icon = source.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "macwindow").frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(source.appName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if source.isDeviceLike {
                    Image(systemName: "iphone").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var permissionHelp: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "eye.slash").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Screen Recording permission needed").font(.system(size: 14, weight: .medium))
            Text("Grant pass Screen Recording access in System Settings, then relaunch pass. Mirroring only reads the chosen window's pixels — nothing leaves your Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack {
                Button("Open System Settings") {
                    let raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
                }
                Button("Check again") { Task { await engine.refreshSources() } }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyHelp: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "macwindow.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("No windows to mirror").font(.system(size: 14, weight: .medium))
            Text(engine.listError ?? "Start the iOS Simulator or an Android emulator (or bring the device window on screen), then refresh.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Live mirror

    private var live: some View {
        MirrorFrameView(engine: engine)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { controls }
            .onHover { hoveringControls = $0 }
    }

    /// Compact toolbar floating over the video — near-invisible until the mouse is over the
    /// mirror, so the panel reads as a pure device screen.
    private var controls: some View {
        HStack(spacing: 10) {
            Button { engine.returnToPicker() } label: { Image(systemName: "chevron.left") }
                .help("Back to the window list")
            Text(engine.activeSource?.displayTitle ?? "")
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer(minLength: 12)
            Button { onToggleFloat() } label: { Image(systemName: floats ? "pin.fill" : "pin") }
                .help(floats ? "Stop floating above other windows" : "Float above other windows")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(8)
        .opacity(hoveringControls ? 1 : 0.25)
        .animation(.easeOut(duration: 0.15), value: hoveringControls)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
            Text("Mirror stopped").font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Choose a window") { engine.returnToPicker() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
