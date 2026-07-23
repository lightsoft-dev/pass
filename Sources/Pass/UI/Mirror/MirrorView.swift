import AppKit
import SwiftUI

/// Shared session-titlebar control for opening the physical-device/emulator workspace pane.
struct DevicePaneButton: View {
    let sessionName: String

    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button { appModel.mirror.openPicker(for: sessionName) } label: {
            Image(systemName: "iphone.and.arrow.forward")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Attach physical device or emulator pane")
        .accessibilityLabel("Open device pane")
    }
}

/// Device picker and live video surface rendered inside a session workspace split.
struct MirrorView: View {
    let engine: MirrorEngine

    @State private var networkAddress = ""
    @State private var pairingAddress = ""
    @State private var pairingCode = ""

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            switch engine.state {
            case .pickingDevice:
                picker
            case .launching(let device):
                streamSurface(device: device, isLaunching: true)
            case .streaming(let device):
                streamSurface(device: device, isLaunching: false)
            case .failed(let message):
                failed(message)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var paneHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "iphone.and.arrow.forward")
                .foregroundStyle(.secondary)
            Text("Device")
                .font(.system(size: 11, weight: .semibold))
            if case .streaming(let device) = engine.state {
                Text("· \(device.displayName)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if !device.supportsPointerInput {
                    Text("VIEW ONLY")
                        .font(.system(size: 7, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            Spacer()
            if case .pickingDevice = engine.state {
                if engine.isRefreshing { ProgressView().controlSize(.mini) }
                Button { Task { await engine.refreshDevices() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).help("Refresh devices")
            } else {
                Button("Devices") { engine.returnToPicker() }
                    .buttonStyle(.plain).font(.system(size: 10))
            }
            Button { engine.detach() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain).help("Close device pane")
        }
        .padding(.horizontal, 10).frame(height: 31)
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                if !engine.devices.isEmpty {
                    sectionTitle("Mobile devices & emulators")
                    VStack(spacing: 5) {
                        ForEach(engine.devices) { device in
                            Button { engine.start(device) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: icon(for: device.transport))
                                        .frame(width: 19).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(device.displayName).font(.system(size: 11, weight: .medium))
                                        Text(device.detailText).font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text("\(device.platform.label) · \(device.transport.label)")
                                        .font(.system(size: 8, weight: .semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                .padding(8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                            .disabled(engine.unavailableReason(for: device) != nil)
                        }
                    }
                } else if !engine.isRefreshing {
                    notice(icon: "iphone.slash", title: "No authorized target",
                           detail: "Connect and unlock an iPhone or iPad over USB, then trust this Mac. For Android, enable USB debugging or start an emulator.")
                }

                if let problem = engine.toolProblem {
                    notice(icon: "wrench.and.screwdriver", title: "Android unavailable",
                           detail: problem)
                }

                sectionTitle("Connect an Android device over Wi-Fi")
                HStack(spacing: 6) {
                    TextField("192.168.0.24:5555", text: $networkAddress)
                        .textFieldStyle(.roundedBorder)
                    Button(engine.isConnecting ? "…" : "Connect") {
                        Task {
                            if await engine.connectNetwork(networkAddress) { networkAddress = "" }
                        }
                    }
                    .disabled(engine.isConnecting || networkAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                DisclosureGroup("Pair Android 11+ wireless debugging") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Pairing IP:port", text: $pairingAddress).textFieldStyle(.roundedBorder)
                        HStack(spacing: 6) {
                            TextField("6-digit code", text: $pairingCode).textFieldStyle(.roundedBorder)
                            Button(engine.isPairing ? "…" : "Pair") {
                                Task {
                                    if await engine.pairNetwork(pairingAddress, code: pairingCode) {
                                        pairingAddress = ""; pairingCode = ""
                                    }
                                }
                            }
                            .disabled(engine.isPairing || pairingAddress.isEmpty || pairingCode.isEmpty)
                        }
                        Text("Pairing and connection ports shown by Android are often different.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 10, weight: .medium))

                if let message = engine.connectionMessage {
                    Text(message).font(.system(size: 9)).foregroundStyle(.green)
                }
                if let error = engine.listError, !error.isEmpty {
                    Text(error).font(.system(size: 9)).foregroundStyle(.red).textSelection(.enabled)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text("Video travels directly through ADB for Android or Apple's trusted USB capture path for iOS. Pass does not capture the Mac screen.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(11)
        }
        .task { await engine.refreshDevices() }
    }

    private func streamSurface(device: MirrorDevice, isLaunching: Bool) -> some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image = engine.frame {
                    Image(nsImage: image)
                        .resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if device.supportsPointerInput {
                        inputOverlay(imageSize: image.size, container: geo.size)
                    }
                }
                if isLaunching || engine.frame == nil {
                    VStack(spacing: 9) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Starting \(device.displayName)…")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                if !isLaunching, engine.frame != nil, !device.supportsPointerInput {
                    VStack {
                        Spacer()
                        Text("Use the iPhone or iPad for input")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(9)
                    }
                }
            }
        }
    }

    private func inputOverlay(imageSize: NSSize, container: CGSize) -> some View {
        let scale = min(container.width / max(1, imageSize.width),
                        container.height / max(1, imageSize.height))
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (container.width - shown.width) / 2,
                             y: (container.height - shown.height) / 2)
        return Color.clear
            .frame(width: shown.width, height: shown.height)
            .position(x: origin.x + shown.width / 2, y: origin.y + shown.height / 2)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let start = CGPoint(x: value.startLocation.x / scale,
                                        y: value.startLocation.y / scale)
                    let end = CGPoint(x: value.location.x / scale,
                                      y: value.location.y / scale)
                    if hypot(end.x - start.x, end.y - start.y) < 8 {
                        engine.tap(x: Int(end.x), y: Int(end.y))
                    } else {
                        engine.swipe(from: start, to: end)
                    }
                })
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 25)).foregroundStyle(.orange)
            Text("Device mirror unavailable").font(.system(size: 12, weight: .medium))
            Text(message).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled).padding(.horizontal, 12)
            Button("Back to devices") { engine.returnToPicker() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func notice(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .semibold))
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(9).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }

    private func icon(for transport: MirrorDevice.Transport) -> String {
        switch transport {
        case .usb: return "cable.connector"
        case .network: return "wifi"
        case .emulator: return "apps.iphone"
        }
    }
}
