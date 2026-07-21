import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import Observation
import ScreenCaptureKit

/// One capturable on-screen window offered as a mirror source. Device windows — simulators,
/// emulators, and real hardware shown through QuickTime or scrcpy — rank first, but every
/// normal window is offered so unusual setups keep working.
struct MirrorSource: Identifiable {
    let window: SCWindow
    let appName: String
    let title: String
    let isDeviceLike: Bool

    var id: CGWindowID { window.windowID }
    var displayTitle: String { title.isEmpty ? appName : title }
    var icon: NSImage? {
        guard let pid = window.owningApplication?.processID else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }
}

/// Owns the ScreenCaptureKit stream behind the device-mirror window: lists capturable
/// windows, starts/stops the live stream, and hands each frame's IOSurface to the view.
@MainActor
@Observable
final class MirrorEngine {
    enum State: Equatable {
        case pickingSource
        case streaming
        case failed(String)
    }

    private(set) var state: State = .pickingSource
    private(set) var sources: [MirrorSource] = []
    private(set) var isRefreshing = false
    private(set) var activeSource: MirrorSource?
    /// macOS denied Screen Recording — the picker explains and links System Settings.
    private(set) var permissionDenied = false
    /// A non-permission listing failure (shown in the picker's empty state).
    private(set) var listError: String?
    /// Pixel size of the live stream — drives the panel's aspect-ratio lock.
    private(set) var contentSize: CGSize = .zero

    /// Latest frame's IOSurface, delivered on the main queue. The engine retains the sample
    /// buffer until the next frame arrives so the surface on screen is never recycled
    /// mid-display by the stream's buffer pool.
    @ObservationIgnored var onFrame: ((IOSurfaceRef) -> Void)?
    /// Stream lifecycle for the window controller: (pixel size or .zero, source name or nil).
    @ObservationIgnored var onStreamChange: ((CGSize, String?) -> Void)?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: MirrorStreamOutput?
    @ObservationIgnored private var lastFrame: CMSampleBuffer?
    /// Bumped on every stream teardown/start so in-flight callbacks from a replaced stream
    /// can be recognized and dropped.
    @ObservationIgnored private var generation = 0

    private static let captureQueue = DispatchQueue(label: "pass.mirror.capture", qos: .userInteractive)

    /// Apps whose windows look like a device screen, matched against the lowercased app name
    /// and bundle id. "qemu" is the Android emulator's actual process on macOS; QuickTime and
    /// scrcpy are how real iPhones/Android devices get an on-screen window to mirror.
    private static let deviceHints = ["simulator", "emulator", "qemu", "scrcpy", "vysor", "quicktime"]

    /// The mirror window just (re)appeared — refresh the list if the picker is up.
    func windowShown() {
        if state == .pickingSource {
            Task { await refreshSources() }
        }
    }

    func refreshSources() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        listError = nil
        // Preflight so a denial shows guidance instead of an empty list. The request call
        // shows the system prompt the first time and is a no-op after a decision.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        guard CGPreflightScreenCaptureAccess() else {
            permissionDenied = true
            sources = []
            return
        }
        permissionDenied = false
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            sources = content.windows
                .filter { window in
                    window.isOnScreen
                        && window.windowLayer == 0
                        && window.frame.width >= 80 && window.frame.height >= 80
                        && window.owningApplication?.processID != ownPID
                }
                .map { window in
                    let app = window.owningApplication
                    let haystack = "\(app?.applicationName ?? "") \(app?.bundleIdentifier ?? "")".lowercased()
                    return MirrorSource(
                        window: window,
                        appName: app?.applicationName ?? "Unknown app",
                        title: window.title ?? "",
                        isDeviceLike: Self.deviceHints.contains { haystack.contains($0) }
                    )
                }
                .sorted { a, b in
                    if a.isDeviceLike != b.isDeviceLike { return a.isDeviceLike }
                    return (a.appName.lowercased(), a.displayTitle) < (b.appName.lowercased(), b.displayTitle)
                }
        } catch {
            sources = []
            permissionDenied = !CGPreflightScreenCaptureAccess()
            listError = permissionDenied ? nil : error.localizedDescription
            Log.ui.error("mirror: listing windows failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start(_ source: MirrorSource) async {
        teardownStream()
        let filter = SCContentFilter(desktopIndependentWindow: source.window)
        // contentRect/pointPixelScale give the exact retina pixel size; fall back to the
        // window frame if the filter reports nothing useful.
        var pointSize = filter.contentRect.size
        if pointSize.width < 1 || pointSize.height < 1 { pointSize = source.window.frame.size }
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let pixelWidth = max(2, Int((pointSize.width * scale).rounded()))
        let pixelHeight = max(2, Int((pointSize.height * scale).rounded()))

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        generation &+= 1
        let gen = generation
        let output = MirrorStreamOutput(
            onSurface: { [weak self] buffer, surface in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.present(buffer: buffer, surface: surface, generation: gen)
                    }
                }
            },
            onStopped: { [weak self] message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.streamDied(message, generation: gen) }
                }
            }
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: Self.captureQueue)
            try await stream.startCapture()
        } catch {
            state = .failed(error.localizedDescription)
            Log.ui.error("mirror: start failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.stream = stream
        self.output = output
        activeSource = source
        contentSize = CGSize(width: pixelWidth, height: pixelHeight)
        state = .streaming
        onStreamChange?(contentSize, source.displayTitle)
        Log.ui.info("mirror: streaming \(source.appName, privacy: .public) at \(pixelWidth)x\(pixelHeight)")
    }

    /// Back to the source picker (stops any live stream and re-lists windows).
    func returnToPicker() {
        teardownStream()
        contentSize = .zero
        state = .pickingSource
        onStreamChange?(.zero, nil)
        Task { await refreshSources() }
    }

    /// The mirror window closed — stop capturing but keep the engine reusable for next show.
    func shutdown() {
        teardownStream()
        contentSize = .zero
        state = .pickingSource
        onStreamChange?(.zero, nil)
    }

    // MARK: Stream internals

    private func present(buffer: CMSampleBuffer, surface: IOSurfaceRef, generation gen: Int) {
        guard gen == generation, state == .streaming else { return }
        lastFrame = buffer
        onFrame?(surface)
    }

    /// The stream ended on its own — usually because the mirrored window closed.
    private func streamDied(_ message: String, generation gen: Int) {
        guard gen == generation else { return }
        teardownStream()
        contentSize = .zero
        state = .failed(message.isEmpty ? "The mirrored window went away." : message)
        onStreamChange?(.zero, nil)
        Log.ui.info("mirror: stream stopped: \(message, privacy: .public)")
    }

    /// Drop the current stream (if any). Bumps the generation so in-flight callbacks from the
    /// old stream are ignored; the actual stopCapture happens asynchronously.
    private func teardownStream() {
        generation &+= 1
        activeSource = nil
        lastFrame = nil
        output = nil
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }
}

/// Receives SCStream callbacks on the capture queue and forwards displayable frames. Kept
/// off the main actor: ScreenCaptureKit calls these from its own queue.
private final class MirrorStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onSurface: (CMSampleBuffer, IOSurfaceRef) -> Void
    private let onStopped: (String) -> Void

    init(onSurface: @escaping (CMSampleBuffer, IOSurfaceRef) -> Void,
         onStopped: @escaping (String) -> Void) {
        self.onSurface = onSurface
        self.onStopped = onStopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        // Only .complete frames carry displayable content (idle/suspended frames don't).
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        onSurface(sampleBuffer, surface)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped(error.localizedDescription)
    }
}
