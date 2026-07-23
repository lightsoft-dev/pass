import AppKit
import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation

/// Finds the iOS screen-capture devices that macOS exposes for trusted USB devices.
///
/// These are the same CoreMediaIO devices used by QuickTime Player. They are distinct from
/// Continuity Camera devices: screen devices report `modelID == "iOS Device"`.
enum MirrorIOSDeviceDiscovery {
    static func discover() -> [MirrorDevice] {
        enableScreenCaptureDevices()

        let externalDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: nil,
            position: .unspecified
        )
        .devices
        let screenDevices = externalDevices.filter {
            isIOSScreenCaptureDevice(modelID: $0.modelID, manufacturer: $0.manufacturer)
        }

        Log.ui.debug(
            "iOS screen discovery found \(screenDevices.count, privacy: .public) screen devices among \(externalDevices.count, privacy: .public) external capture devices"
        )
        for device in externalDevices where !screenDevices.contains(device) {
            Log.ui.debug(
                "Ignored external capture device model=\(device.modelID, privacy: .public) manufacturer=\(device.manufacturer, privacy: .public)"
            )
        }

        return screenDevices.map {
            MirrorDevice(
                serial: $0.uniqueID,
                name: $0.localizedName.isEmpty ? "iPhone or iPad" : $0.localizedName,
                product: $0.modelID,
                platform: .iOS,
                transport: .usb
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func isIOSScreenCaptureDevice(modelID: String, manufacturer: String) -> Bool {
        modelID.caseInsensitiveCompare("iOS Device") == .orderedSame
            && manufacturer.caseInsensitiveCompare("Apple Inc.") == .orderedSame
    }

    private static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allowed: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout.size(ofValue: allowed)),
            &allowed
        )
        if status != noErr {
            Log.ui.error(
                "Could not enable CoreMediaIO screen devices (OSStatus \(status, privacy: .public))"
            )
        }
    }
}

/// Owns one native iPhone/iPad capture session. All AVFoundation work and frame conversion
/// stays off the main actor; the engine receives immutable CGImages through callbacks.
final class MirrorIOSCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                              @unchecked Sendable {
    typealias FrameHandler = @MainActor @Sendable (CGImage) -> Void
    typealias FailureHandler = @Sendable (String) -> Void

    private let deviceID: String
    private let frameHandler: FrameHandler
    private let failureHandler: FailureHandler
    private let queue = DispatchQueue(label: "dev.lightsoft.pass.ios-mirror", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let stateLock = NSLock()
    private let deliveryLock = NSLock()

    private var stopped = false
    private var failureReported = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastFrameTime = CMTime.invalid
    private var lastFrameUptime: UInt64 = 0
    private var watchdog: DispatchSourceTimer?
    private var pendingFrame: CGImage?
    private var isFrameDeliveryScheduled = false

    init(deviceID: String, frameHandler: @escaping FrameHandler,
         failureHandler: @escaping FailureHandler) {
        self.deviceID = deviceID
        self.frameHandler = frameHandler
        self.failureHandler = failureHandler
    }

    static func requestVideoAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) {
                    continuation.resume(returning: $0)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() {
        queue.async { [self] in
            guard !isStopped else { return }
            do {
                try configure()
                guard !isStopped else { return }
                session.startRunning()
                if !session.isRunning {
                    reportFailure("The iPhone screen capture session could not start.")
                } else {
                    startWatchdog()
                }
            } catch {
                reportFailure("Could not start the iPhone screen stream: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        stateLock.lock()
        let wasStopped = stopped
        stopped = true
        stateLock.unlock()
        guard !wasStopped else { return }

        deliveryLock.lock()
        pendingFrame = nil
        deliveryLock.unlock()
        queue.async { [self] in
            watchdog?.cancel()
            watchdog = nil
            if session.isRunning { session.stopRunning() }
            removeObservers()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !isStopped else { return }

        // The source can produce 60 fps. Match the Android pane's 30 fps ceiling and avoid
        // spending the capture queue on frames SwiftUI cannot present.
        lastFrameUptime = DispatchTime.now().uptimeNanoseconds
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastFrameTime.isValid,
           CMTimeCompare(timestamp, lastFrameTime) >= 0,
           CMTimeCompare(timestamp, CMTimeAdd(lastFrameTime, CMTime(value: 1, timescale: 30))) < 0 {
            return
        }
        lastFrameTime = timestamp

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return }
        enqueueForDelivery(cgImage)
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func configure() throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected else {
            throw MirrorIOSCaptureError.deviceUnavailable
        }
        guard !device.isInUseByAnotherApplication else {
            throw MirrorIOSCaptureError.deviceInUse
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard session.canAddInput(input) else {
            throw MirrorIOSCaptureError.cannotAddInput
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw MirrorIOSCaptureError.cannotAddOutput
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video),
           connection.isVideoMinFrameDurationSupported {
            connection.videoMinFrameDuration = CMTime(value: 1, timescale: 30)
        }

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            if error?.domain == AVFoundationErrorDomain,
               error?.code == AVError.Code.deviceInUseByAnotherApplication.rawValue {
                self?.reportFailure(
                    "The iPhone or iPad screen is in use by another app. Close QuickTime or other capture apps and try again."
                )
            } else {
                self?.reportFailure(
                    error?.localizedDescription ?? "The iPhone screen capture session stopped."
                )
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.reportFailure(
                "The iPhone screen stream was interrupted. Keep the device unlocked, close other capture apps, and try again."
            )
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.didStopRunningNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.reportFailure(
                "The iPhone screen stream stopped. Keep the device unlocked, then try again."
            )
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
        ) { [weak self] _ in
            self?.reportFailure("The iPhone or iPad was disconnected.")
        })
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped, self.lastFrameUptime != 0 else { return }
            let elapsed = DispatchTime.now().uptimeNanoseconds - self.lastFrameUptime
            if elapsed > 5_000_000_000 {
                self.reportFailure(
                    "The iPhone screen stopped sending video. Keep the device unlocked, then try again."
                )
            }
        }
        watchdog = timer
        timer.resume()
    }

    /// Keep at most one not-yet-presented frame. `alwaysDiscardsLateVideoFrames` only protects
    /// the capture queue; without this second boundary a busy main queue could retain many
    /// full-resolution CGImages.
    private func enqueueForDelivery(_ image: CGImage) {
        deliveryLock.lock()
        pendingFrame = image
        let shouldSchedule = !isFrameDeliveryScheduled
        isFrameDeliveryScheduled = true
        deliveryLock.unlock()
        guard shouldSchedule else { return }
        schedulePendingFrameDelivery()
    }

    private func schedulePendingFrameDelivery() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.deliverPendingFrame()
            }
        }
    }

    @MainActor
    private func deliverPendingFrame() {
        deliveryLock.lock()
        let image = pendingFrame
        pendingFrame = nil
        deliveryLock.unlock()

        if !isStopped, let image { frameHandler(image) }

        deliveryLock.lock()
        let hasNewerFrame = pendingFrame != nil
        if !hasNewerFrame { isFrameDeliveryScheduled = false }
        deliveryLock.unlock()
        if hasNewerFrame { schedulePendingFrameDelivery() }
    }

    private func reportFailure(_ message: String) {
        stateLock.lock()
        let shouldReport = !stopped && !failureReported
        failureReported = true
        stateLock.unlock()
        if shouldReport { failureHandler(message) }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }
}

private enum MirrorIOSCaptureError: LocalizedError {
    case deviceUnavailable
    case deviceInUse
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "The iPhone or iPad is no longer available. Reconnect and trust this Mac."
        case .deviceInUse:
            return "The iPhone or iPad screen is in use by another app. Close QuickTime or other capture apps and try again."
        case .cannotAddInput:
            return "macOS could not use the iPhone screen as a capture input."
        case .cannotAddOutput:
            return "macOS could not create a video output for the iPhone screen."
        }
    }
}
