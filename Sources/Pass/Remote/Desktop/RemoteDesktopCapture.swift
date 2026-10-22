#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// A ScreenCaptureKit video sample. `pixelBuffer` is NV12 (420v) and can be wrapped by a
/// WebRTC video source; `sampleBuffer` keeps its IOSurface alive until the consumer releases it.
struct RemoteDesktopVideoFrame {
    let displayID: CGDirectDisplayID
    let sampleBuffer: CMSampleBuffer

    var pixelBuffer: CVPixelBuffer? { CMSampleBufferGetImageBuffer(sampleBuffer) }
    var presentationTime: CMTime { CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
    var width: Int { pixelBuffer.map(CVPixelBufferGetWidth) ?? 0 }
    var height: Int { pixelBuffer.map(CVPixelBufferGetHeight) ?? 0 }
}

/// ScreenCaptureKit may deliver faster than a video encoder or network consumer can process.
/// This one-frame mailbox always replaces a stale pending frame rather than growing a queue.
final class RemoteDesktopFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let onFrame: (RemoteDesktopVideoFrame) -> Void
    private let onFailure: (String) -> Void
    private let deliveryQueue = DispatchQueue(label: "dev.lightsoft.pass.remote-desktop.frames", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var pendingFrame: RemoteDesktopVideoFrame?
    private var deliveryScheduled = false

    init(
        displayID: CGDirectDisplayID,
        onFrame: @escaping (RemoteDesktopVideoFrame) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.displayID = displayID
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func deactivate() {
        lock.lock()
        active = false
        pendingFrame = nil
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete else { return }

        lock.lock()
        guard active else { lock.unlock(); return }
        pendingFrame = RemoteDesktopVideoFrame(displayID: displayID, sampleBuffer: sampleBuffer)
        let shouldSchedule = !deliveryScheduled
        if shouldSchedule { deliveryScheduled = true }
        lock.unlock()

        if shouldSchedule {
            deliveryQueue.async { [weak self] in self?.deliverLatestFrames() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        let wasActive = active
        active = false
        pendingFrame = nil
        lock.unlock()
        if wasActive { onFailure(error.localizedDescription) }
    }

    private func deliverLatestFrames() {
        while true {
            lock.lock()
            guard active, let frame = pendingFrame else {
                deliveryScheduled = false
                lock.unlock()
                return
            }
            pendingFrame = nil
            lock.unlock()
            onFrame(frame)
        }
    }
}
#endif
