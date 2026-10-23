#if os(macOS)
import ApplicationServices
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum RemoteDesktopHostError: Error, LocalizedError {
    case disabled
    case controllerNotApproved
    case approvalExpired
    case captureAlreadyActive
    case captureNotActive
    case screenRecordingPermissionRequired
    case accessibilityPermissionRequired
    case displayUnavailable
    case invalidInput
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .disabled: "Remote desktop sharing is off on this Mac."
        case .controllerNotApproved: "This device has not been approved on this Mac."
        case .approvalExpired: "This remote desktop approval has expired."
        case .captureAlreadyActive: "A remote desktop session is already active."
        case .captureNotActive: "There is no active remote desktop session for this device."
        case .screenRecordingPermissionRequired: "Grant Pass Screen Recording access in System Settings."
        case .accessibilityPermissionRequired: "Grant Pass Accessibility access before allowing remote input."
        case .displayUnavailable: "The requested display is no longer available."
        case .invalidInput: "The remote input event is invalid."
        case .inputUnavailable: "The system could not create the input event."
        }
    }
}

enum RemoteDesktopHostState: Equatable {
    case disabled
    case ready
    case starting
    case capturing(controllerID: String, displayID: CGDirectDisplayID)
    case stopping
    case failed(String)
}

struct RemoteDesktopDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let width: Int
    let height: Int
    let frame: CGRect
}

/// Local host boundary for remote screen viewing and input. The caller supplies only a
/// relay-verified device ID as `controllerID`; it must never use an untrusted payload value.
/// No relay or WebRTC types cross this boundary. Approval is in memory and starts empty.
@MainActor
final class RemoteDesktopHost {
    private struct Capture {
        let controllerID: String
        let displayID: CGDirectDisplayID
        let stream: SCStream
        let output: RemoteDesktopFrameOutput
    }

    private(set) var state: RemoteDesktopHostState = .disabled
    var approvedControllerIDs: Set<String> {
        Set(approvalExpirations.compactMap { $0.value > Date() ? $0.key : nil })
    }
    var isEnabled: Bool { enabled }
    var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }
    var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }
    /// The coordinator closes its relay lease and WebRTC peer when capture stops unexpectedly.
    var onCaptureFailure: ((String) -> Void)?

    private var enabled = false
    private var approvalExpirations: [String: Date] = [:]
    private var approvalExpiryTasks: [String: Task<Void, Never>] = [:]
    private var capture: Capture?
    private var startingControllerID: String?
    private var streamTeardownTask: Task<Void, Never>?
    private var generation = 0
    private let inputInjector = RemoteDesktopInputInjector()

    /// Call from a local host UI action. Disabling clears approvals and stops capture.
    func setEnabled(_ newValue: Bool) async {
        guard enabled != newValue else { return }
        enabled = newValue
        if newValue {
            if streamTeardownTask == nil { state = .ready }
        } else {
            approvalExpiryTasks.values.forEach { $0.cancel() }
            approvalExpiryTasks.removeAll()
            approvalExpirations.removeAll()
            await stopCapture()
            state = enabled ? .ready : .disabled
        }
    }

    /// These methods may show macOS permission prompts. Invoke them only from an explicit
    /// local action, not automatically when a remote device asks for a session.
    @discardableResult
    func requestScreenRecordingPermission() -> Bool { CGRequestScreenCaptureAccess() }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Call only after a person approves the relay-verified device ID in the host UI.
    func approve(controllerID: String, expiresAt: Date) throws {
        guard enabled else { throw RemoteDesktopHostError.disabled }
        guard !controllerID.isEmpty else { throw RemoteDesktopHostError.controllerNotApproved }
        guard expiresAt > Date() else { throw RemoteDesktopHostError.approvalExpired }
        approvalExpiryTasks.removeValue(forKey: controllerID)?.cancel()
        approvalExpirations[controllerID] = expiresAt
        approvalExpiryTasks[controllerID] = Task { [weak self] in
            // Use wall time because the relay sends an absolute expiry. Recheck after
            // every bounded sleep so a clock change cannot keep approval alive.
            while expiresAt > Date() {
                let seconds = min(expiresAt.timeIntervalSinceNow, 3_600)
                do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
                catch { return }
            }
            await self?.expireApproval(controllerID: controllerID, expiresAt: expiresAt)
        }
    }

    /// Also use for a disconnect or expired relay session. Any held input is released.
    func revoke(controllerID: String) async {
        approvalExpiryTasks.removeValue(forKey: controllerID)?.cancel()
        approvalExpirations.removeValue(forKey: controllerID)
        if capture?.controllerID == controllerID || startingControllerID == controllerID {
            await stopCapture()
        }
    }

    func availableDisplays() async throws -> [RemoteDesktopDisplay] {
        guard enabled else { throw RemoteDesktopHostError.disabled }
        guard hasScreenRecordingAccess else { throw RemoteDesktopHostError.screenRecordingPermissionRequired }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map {
            RemoteDesktopDisplay(id: $0.displayID, width: $0.width, height: $0.height, frame: $0.frame)
        }
    }

    /// Frames arrive on a dedicated serial queue. The callback should hand the sample to a
    /// video pipeline promptly; slow consumers receive the newest frame and skip older ones.
    func startCapture(
        controllerID: String,
        displayID: CGDirectDisplayID,
        onFrame: @escaping (RemoteDesktopVideoFrame) -> Void
    ) async throws {
        guard enabled else { throw RemoteDesktopHostError.disabled }
        guard hasApproval(for: controllerID) else {
            throw RemoteDesktopHostError.controllerNotApproved
        }
        guard capture == nil, streamTeardownTask == nil,
              state != .starting, state != .stopping else {
            throw RemoteDesktopHostError.captureAlreadyActive
        }
        guard hasScreenRecordingAccess else { throw RemoteDesktopHostError.screenRecordingPermissionRequired }

        generation &+= 1
        let requestGeneration = generation
        startingControllerID = controllerID
        state = .starting
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RemoteDesktopHostError.displayUnavailable
            }
            guard generation == requestGeneration, enabled, hasApproval(for: controllerID) else {
                throw CancellationError()
            }

            let config = SCStreamConfiguration()
            let (width, height) = Self.outputSize(for: displayID)
            config.width = width
            config.height = height
            config.scalesToFit = true
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 3
            config.showsCursor = true
            config.capturesAudio = false

            let output = RemoteDesktopFrameOutput(
                displayID: displayID,
                onFrame: onFrame,
                onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        await self?.handleStreamFailure(message, generation: requestGeneration)
                    }
                }
            )
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "dev.lightsoft.pass.remote-desktop.capture", qos: .userInitiated)
            )
            capture = Capture(controllerID: controllerID, displayID: displayID, stream: stream, output: output)
            try await stream.startCapture()
            guard generation == requestGeneration, enabled, hasApproval(for: controllerID) else {
                output.deactivate()
                if capture?.stream === stream {
                    await stopCapture()
                } else {
                    await streamTeardownTask?.value
                    // A stop may have raced with startCapture's await and finished before
                    // ScreenCaptureKit reported a successful start. Stop that late stream too.
                    _ = try? await stream.stopCapture()
                }
                throw CancellationError()
            }
            startingControllerID = nil
            state = .capturing(controllerID: controllerID, displayID: displayID)
        } catch {
            if generation == requestGeneration {
                startingControllerID = nil
                let failedCapture = capture
                capture = nil
                failedCapture?.output.deactivate()
                inputInjector.releaseAllInput()
                state = enabled ? .failed(error.localizedDescription) : .disabled
                if let failedCapture {
                    let teardown = Task<Void, Never> {
                        _ = try? await failedCapture.stream.stopCapture()
                    }
                    streamTeardownTask = teardown
                    await teardown.value
                    streamTeardownTask = nil
                }
            }
            throw error
        }
    }

    /// Close the active session before starting another one. Stop immediately blocks frames and
    /// input, then waits for ScreenCaptureKit to finish tearing down its stream.
    func stopCapture() async {
        if let streamTeardownTask {
            inputInjector.releaseAllInput()
            await streamTeardownTask.value
            return
        }
        generation &+= 1
        let stopGeneration = generation
        startingControllerID = nil
        let previous = capture
        capture = nil
        previous?.output.deactivate()
        inputInjector.releaseAllInput()
        guard let previous else {
            state = enabled ? .ready : .disabled
            return
        }
        state = .stopping
        let teardown = Task<Void, Never> { _ = try? await previous.stream.stopCapture() }
        streamTeardownTask = teardown
        await teardown.value
        streamTeardownTask = nil
        if generation == stopGeneration { state = enabled ? .ready : .disabled }
    }

    func releaseAllInput() { inputInjector.releaseAllInput() }

    /// The decoded event still cannot reach CGEvent unless host state and TCC both permit it.
    func inject(_ event: RemoteDesktopInputEvent, controllerID: String) throws {
        guard enabled else { throw RemoteDesktopHostError.disabled }
        guard hasApproval(for: controllerID) else {
            if capture?.controllerID == controllerID {
                capture?.output.deactivate()
                inputInjector.releaseAllInput()
                Task { await revoke(controllerID: controllerID) }
            }
            throw RemoteDesktopHostError.controllerNotApproved
        }
        guard let capture, capture.controllerID == controllerID,
              case .capturing = state else { throw RemoteDesktopHostError.captureNotActive }
        guard hasAccessibilityAccess else { throw RemoteDesktopHostError.accessibilityPermissionRequired }
        try inputInjector.inject(event, displayID: capture.displayID)
    }

    private func handleStreamFailure(_ message: String, generation failedGeneration: Int) async {
        guard generation == failedGeneration else { return }
        generation &+= 1
        let previous = capture
        capture = nil
        startingControllerID = nil
        previous?.output.deactivate()
        inputInjector.releaseAllInput()
        state = enabled ? .failed(message) : .disabled
        let teardown = previous.map { previous in
            Task<Void, Never> { _ = try? await previous.stream.stopCapture() }
        }
        streamTeardownTask = teardown
        onCaptureFailure?(message)
        await teardown?.value
        streamTeardownTask = nil
    }

    private func hasApproval(for controllerID: String) -> Bool {
        guard let expiresAt = approvalExpirations[controllerID] else { return false }
        return expiresAt > Date()
    }

    private func expireApproval(controllerID: String, expiresAt: Date) async {
        guard approvalExpirations[controllerID] == expiresAt else { return }
        guard expiresAt <= Date() else { return }
        await revoke(controllerID: controllerID)
    }

    private static func outputSize(for displayID: CGDirectDisplayID) -> (Int, Int) {
        let nativeWidth = max(2, CGDisplayPixelsWide(displayID))
        let nativeHeight = max(2, CGDisplayPixelsHigh(displayID))
        let scale = min(1.0, 1920.0 / Double(max(nativeWidth, nativeHeight)))
        // NV12 encoders need even dimensions. Keep aspect while bounding frame bandwidth.
        let width = max(2, Int(Double(nativeWidth) * scale) / 2 * 2)
        let height = max(2, Int(Double(nativeHeight) * scale) / 2 * 2)
        return (width, height)
    }
}
#endif
