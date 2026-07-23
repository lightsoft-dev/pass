import AppKit
import Darwin
import Foundation
import Observation

/// An Android target visible to adb. Physical devices and Android emulators use the same
/// direct stream; only their transport label differs in the picker.
struct MirrorDevice: Identifiable, Equatable, Sendable {
    enum Transport: String, Sendable {
        case usb
        case network
        case emulator

        var label: String {
            switch self {
            case .usb: return "USB"
            case .network: return "Wi-Fi"
            case .emulator: return "Emulator"
            }
        }
    }

    let serial: String
    let name: String
    let product: String?
    let transport: Transport

    var id: String { serial }
    var displayName: String { name.isEmpty ? serial : name }
}

struct MirrorADBDevicesParser {
    static func parse(_ output: String) -> [MirrorDevice] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { raw in
            let fields = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            let serial = fields[0]
            let metadata = Dictionary(uniqueKeysWithValues: fields.dropFirst(2).compactMap { field -> (String, String)? in
                guard let colon = field.firstIndex(of: ":") else { return nil }
                return (String(field[..<colon]), String(field[field.index(after: colon)...]))
            })
            let model = metadata["model"]?.replacingOccurrences(of: "_", with: " ")
            let product = metadata["product"]?.replacingOccurrences(of: "_", with: " ")
            let transport: MirrorDevice.Transport
            if serial.hasPrefix("emulator-") {
                transport = .emulator
            } else if serial.contains(":") {
                transport = .network
            } else {
                transport = .usb
            }
            return MirrorDevice(serial: serial, name: model ?? product ?? serial,
                                product: product, transport: transport)
        }
        .sorted {
            let rank: [MirrorDevice.Transport: Int] = [.usb: 0, .network: 1, .emulator: 2]
            return (rank[$0.transport] ?? 9, $0.displayName.lowercased())
                < (rank[$1.transport] ?? 9, $1.displayName.lowercased())
        }
    }
}

enum MirrorNetworkAddress {
    static func normalized(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        if value.hasPrefix("[") {
            guard value.range(of: #"^\[[0-9A-Fa-f:]+\]:[0-9]{1,5}$"#,
                              options: .regularExpression) != nil else { return nil }
            return validPortSuffix(value) ? value : nil
        }
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let host = pieces.first, !host.isEmpty else { return nil }
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        if pieces.count == 1 { return "\(host):5555" }
        return validPortSuffix(value) ? value : nil
    }

    private static func validPortSuffix(_ value: String) -> Bool {
        guard let rawPort = value.split(separator: ":").last,
              let port = Int(rawPort), (1...65535).contains(port) else { return false }
        return true
    }
}

struct MirrorToolchain: Sendable {
    let adb: String
    let scrcpy: String
    let ffmpeg: String

    static func locate() -> MirrorToolchain? {
        guard let adb = locateADB(),
              let scrcpy = Shell.resolveViaLoginShell("scrcpy"),
              let ffmpeg = Shell.resolveViaLoginShell("ffmpeg") else { return nil }
        return MirrorToolchain(adb: adb, scrcpy: scrcpy, ffmpeg: ffmpeg)
    }

    static func locateADB() -> String? {
        if let path = Shell.resolveViaLoginShell("adb") { return path }
        let sdk = "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        return FileManager.default.isExecutableFile(atPath: sdk) ? sdk : nil
    }
}

/// Direct Android mirror attached to a Pass session workspace. scrcpy produces a headless
/// Matroska stream and ffmpeg turns it into JPEG frames for the SwiftUI pane. This never reads
/// a Mac window, so Screen Recording permission is neither requested nor required.
@MainActor
@Observable
final class MirrorEngine {
    enum State: Equatable {
        case pickingDevice
        case launching(MirrorDevice)
        case streaming(MirrorDevice)
        case failed(String)
    }

    private(set) var state: State = .pickingDevice
    private(set) var devices: [MirrorDevice] = []
    private(set) var attachedSessionName: String?
    private(set) var frame: NSImage?
    private(set) var isRefreshing = false
    private(set) var isConnecting = false
    private(set) var isPairing = false
    private(set) var toolProblem: String?
    private(set) var listError: String?
    private(set) var connectionMessage: String?

    @ObservationIgnored private var scrcpyProcess: Process?
    @ObservationIgnored private var ffmpegProcess: Process?
    @ObservationIgnored private var streamFIFO: URL?
    @ObservationIgnored private var framePipe: Pipe?
    @ObservationIgnored private var streamID: UUID?
    @ObservationIgnored private var logURL: URL?
    @ObservationIgnored private var logHandle: FileHandle?

    func openPicker(for sessionName: String) {
        if attachedSessionName != sessionName { stopStream() }
        attachedSessionName = sessionName
        if case .streaming = state { return }
        state = .pickingDevice
        Task { await refreshDevices() }
    }

    func refreshDevices() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        listError = nil
        guard let adb = MirrorToolchain.locateADB() else {
            devices = []
            toolProblem = "Android platform-tools are required. Install them with: brew install --cask android-platform-tools"
            return
        }
        let missing = ["scrcpy", "ffmpeg"].filter { Shell.resolveViaLoginShell($0) == nil }
        toolProblem = missing.isEmpty ? nil : "Embedded mirroring requires \(missing.joined(separator: " and ")). Install with: brew install scrcpy ffmpeg"
        let result = await Task.detached { Shell.run(adb, ["devices", "-l"]) }.value
        guard result.ok else {
            devices = []
            listError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        devices = MirrorADBDevicesParser.parse(result.stdout)
    }

    func connectNetwork(_ rawAddress: String) async -> Bool {
        guard let address = MirrorNetworkAddress.normalized(rawAddress) else {
            listError = "Enter a valid device address, for example 192.168.0.24:5555."
            return false
        }
        guard let adb = MirrorToolchain.locateADB() else {
            toolProblem = "adb is not installed. Run: brew install --cask android-platform-tools"
            return false
        }
        isConnecting = true
        defer { isConnecting = false }
        listError = nil
        connectionMessage = nil
        let result = await Task.detached { Shell.run(adb, ["connect", address]) }.value
        guard result.ok, result.stdout.lowercased().contains("connected") else {
            listError = [result.stdout, result.stderr].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return false
        }
        await refreshDevices()
        connectionMessage = "Connected to \(address)."
        return devices.contains { $0.serial == address }
    }

    func pairNetwork(_ rawAddress: String, code rawCode: String) async -> Bool {
        guard let address = MirrorNetworkAddress.normalized(rawAddress), rawAddress.contains(":") else {
            listError = "Enter the pairing address and port shown by Android Wireless debugging."
            return false
        }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            listError = "Enter the 6-digit Wireless debugging pairing code."
            return false
        }
        guard let adb = MirrorToolchain.locateADB() else {
            toolProblem = "adb is not installed. Run: brew install --cask android-platform-tools"
            return false
        }
        isPairing = true
        defer { isPairing = false }
        listError = nil
        connectionMessage = nil
        let result = await Task.detached { Shell.run(adb, ["pair", address, code]) }.value
        guard result.ok, result.stdout.lowercased().contains("successfully paired") else {
            listError = [result.stdout, result.stderr].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return false
        }
        connectionMessage = "Paired with \(address). Now enter the separate connection address above."
        return true
    }

    func start(_ device: MirrorDevice) {
        stopStream()
        guard attachedSessionName != nil else {
            state = .failed("Open a running terminal session before attaching a device pane.")
            return
        }
        guard let tools = MirrorToolchain.locate() else {
            state = .failed("Embedded mirroring requires adb, scrcpy, and ffmpeg.")
            return
        }

        let id = UUID()
        streamID = id
        state = .launching(device)
        frame = nil

        let frames = Pipe()
        let parser = JPEGFrameParser()
        framePipe = frames

        let fifo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pass-device-pane-\(id.uuidString).mkv")
        guard Darwin.mkfifo(fifo.path, 0o600) == 0 else {
            streamID = nil
            state = .failed("Could not create the private device-stream pipe.")
            return
        }
        streamFIFO = fifo

        let diagnostics = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pass-device-pane-\(id.uuidString).log")
        FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
        guard let diagnosticsHandle = FileHandle(forWritingAtPath: diagnostics.path) else {
            state = .failed("Could not create the mirror diagnostic log.")
            return
        }
        logURL = diagnostics
        logHandle = diagnosticsHandle

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: tools.ffmpeg)
        ffmpeg.arguments = [
            "-hide_banner", "-loglevel", "warning", "-i", fifo.path, "-an",
            "-vf", "fps=30", "-c:v", "mjpeg", "-pix_fmt", "yuvj420p",
            "-strict", "unofficial", "-q:v", "4",
            "-f", "image2pipe", "pipe:1",
        ]
        ffmpeg.standardInput = FileHandle.nullDevice
        ffmpeg.standardOutput = frames
        ffmpeg.standardError = diagnosticsHandle

        let scrcpy = Process()
        scrcpy.executableURL = URL(fileURLWithPath: tools.scrcpy)
        scrcpy.arguments = [
            "--serial", device.serial,
            "--no-audio", "--no-video-playback",
            "--record=\(fifo.path)", "--record-format=mkv",
            "--max-size=1920", "--max-fps=60", "--stay-awake",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = tools.adb
        environment["PATH"] = "\(URL(fileURLWithPath: tools.adb).deletingLastPathComponent().path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        scrcpy.environment = environment
        scrcpy.standardOutput = diagnosticsHandle
        scrcpy.standardError = diagnosticsHandle

        frames.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let jpeg = parser.append(data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.streamID == id, let image = NSImage(data: jpeg) else { return }
                    self.frame = image
                    if case .launching = self.state { self.state = .streaming(device) }
                }
            }
        }

        let ended: @Sendable (Process) -> Void = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { self?.streamEnded(id: id) }
            }
        }
        ffmpeg.terminationHandler = ended
        scrcpy.terminationHandler = ended

        do {
            try ffmpeg.run()
            try scrcpy.run()
            ffmpegProcess = ffmpeg
            scrcpyProcess = scrcpy
        } catch {
            if ffmpeg.isRunning { ffmpeg.terminate() }
            streamID = nil
            closePipesAndLog()
            state = .failed("Could not start the embedded device stream: \(error.localizedDescription)")
        }
    }

    func tap(x: Int, y: Int) {
        runInput(["shell", "input", "tap", String(x), String(y)])
    }

    func swipe(from start: CGPoint, to end: CGPoint, duration: Int = 220) {
        runInput(["shell", "input", "swipe", String(Int(start.x)), String(Int(start.y)),
                  String(Int(end.x)), String(Int(end.y)), String(duration)])
    }

    func returnToPicker() {
        stopStream()
        state = .pickingDevice
        Task { await refreshDevices() }
    }

    func detach() {
        stopStream()
        attachedSessionName = nil
        state = .pickingDevice
    }

    func pruneSessions(alive: Set<String>) {
        if let attachedSessionName, !alive.contains(attachedSessionName) { detach() }
    }

    func shutdown() { detach() }

    private func runInput(_ arguments: [String]) {
        guard case .streaming(let device) = state,
              let adb = MirrorToolchain.locateADB() else { return }
        Task.detached { _ = Shell.run(adb, ["-s", device.serial] + arguments) }
    }

    private func streamEnded(id: UUID) {
        guard streamID == id else { return }
        let message = diagnosticTail()
        stopStream()
        state = .failed(message.isEmpty ? "The device stream stopped unexpectedly." : message)
    }

    private func stopStream() {
        streamID = nil
        framePipe?.fileHandleForReading.readabilityHandler = nil
        if scrcpyProcess?.isRunning == true { scrcpyProcess?.terminate() }
        if ffmpegProcess?.isRunning == true { ffmpegProcess?.terminate() }
        scrcpyProcess = nil
        ffmpegProcess = nil
        frame = nil
        closePipesAndLog()
    }

    private func closePipesAndLog() {
        try? framePipe?.fileHandleForWriting.close()
        try? framePipe?.fileHandleForReading.close()
        framePipe = nil
        try? logHandle?.close()
        logHandle = nil
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        logURL = nil
        if let streamFIFO { try? FileManager.default.removeItem(at: streamFIFO) }
        streamFIFO = nil
    }

    private func diagnosticTail() -> String {
        try? logHandle?.synchronize()
        guard let logURL, let data = try? Data(contentsOf: logURL) else { return "" }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).suffix(5).joined(separator: "\n")
    }
}

/// Extracts the newest complete JPEG from ffmpeg's image2pipe byte stream.
final class JPEGFrameParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let start = Data([0xff, 0xd8])
    private let end = Data([0xff, 0xd9])

    func append(_ data: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var newest: Data?
        while let startRange = buffer.range(of: start),
              let endRange = buffer.range(of: end, in: startRange.upperBound..<buffer.endIndex) {
            newest = buffer.subdata(in: startRange.lowerBound..<endRange.upperBound)
            buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
        }
        if buffer.count > 12_000_000 {
            buffer = buffer.suffix(2)
        }
        return newest
    }
}
