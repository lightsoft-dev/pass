#if os(macOS)
import CoreMedia
import Foundation
import WebRTC

struct RemoteDesktopICEServer: Decodable {
    let urls: [String]
    let username: String?
    let credential: String?

    private enum CodingKeys: String, CodingKey { case urls, username, credential }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let single = try? container.decode(String.self, forKey: .urls) {
            urls = [single]
        } else {
            urls = try container.decode([String].self, forKey: .urls)
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
        guard !urls.isEmpty, urls.count <= 16,
              urls.allSatisfy({ $0.count < 256 &&
                  ($0.hasPrefix("stun:") || $0.hasPrefix("turn:") || $0.hasPrefix("turns:")) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .urls, in: container, debugDescription: "Invalid ICE server"
            )
        }
    }
}

struct RemoteDesktopICECandidate: Codable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int

    init(_ candidate: RTCIceCandidate) {
        self.candidate = candidate.sdp
        sdpMid = candidate.sdpMid
        sdpMLineIndex = Int(candidate.sdpMLineIndex)
    }

    func validatedRTC() throws -> RTCIceCandidate {
        guard !candidate.isEmpty, candidate.utf8.count <= 4_096,
              (0...65_535).contains(sdpMLineIndex),
              (sdpMid?.utf8.count ?? 0) <= 256 else {
            throw RemoteDesktopWebRTCError.invalidCandidate
        }
        return RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(sdpMLineIndex), sdpMid: sdpMid)
    }
}

enum RemoteDesktopWebRTCError: Error, LocalizedError {
    case peerUnavailable
    case invalidOffer
    case invalidCandidate
    case answerUnavailable

    var errorDescription: String? {
        switch self {
        case .peerUnavailable: "The screen connection could not be created."
        case .invalidOffer: "The screen offer was invalid."
        case .invalidCandidate: "The screen network candidate was invalid."
        case .answerUnavailable: "The screen answer could not be created."
        }
    }
}

/// WebRTC transports ScreenCaptureKit frames and a single input DataChannel directly between
/// the approved peers. The relay only receives SDP and ICE signaling; it never receives media.
final class RemoteDesktopWebRTCPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private let factory: RTCPeerConnectionFactory
    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let videoTrack: RTCVideoTrack
    private let peer: RTCPeerConnection
    private let canControl: Bool
    private let onICE: (RemoteDesktopICECandidate) -> Void
    private let onInput: (Data) -> Void
    private let onClosed: (String) -> Void
    private let lock = NSLock()
    private var active = true
    private var inputChannel: RTCDataChannel?

    init(
        iceServers: [RemoteDesktopICEServer],
        canControl: Bool,
        onICE: @escaping (RemoteDesktopICECandidate) -> Void,
        onInput: @escaping (Data) -> Void,
        onClosed: @escaping (String) -> Void
    ) throws {
        self.canControl = canControl
        self.onICE = onICE
        self.onInput = onInput
        self.onClosed = onClosed
        factory = RTCPeerConnectionFactory()
        source = factory.videoSource(forScreenCast: true)
        capturer = RTCVideoCapturer(delegate: source)
        videoTrack = factory.videoTrack(with: source, trackId: "pass-screen")

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(
            with: configuration, constraints: constraints, delegate: nil
        ) else { throw RemoteDesktopWebRTCError.peerUnavailable }
        peer = connection
        super.init()
        peer.delegate = self
        guard peer.add(videoTrack, streamIds: ["pass-screen"]) != nil else {
            peer.close()
            throw RemoteDesktopWebRTCError.peerUnavailable
        }
    }

    func push(_ frame: RemoteDesktopVideoFrame) {
        lock.lock()
        let isActive = active
        lock.unlock()
        guard isActive, let pixelBuffer = frame.pixelBuffer else { return }
        let timestamp = frame.presentationTime
        let nanoseconds = timestamp.isValid && timestamp.isNumeric
            ? Int64(CMTimeGetSeconds(timestamp) * 1_000_000_000)
            : Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        let rtcFrame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: nanoseconds
        )
        source.capturer(capturer, didCapture: rtcFrame)
    }

    func acceptOffer(_ sdp: String) async throws -> String {
        guard !sdp.isEmpty, sdp.utf8.count <= 256 * 1_024 else {
            throw RemoteDesktopWebRTCError.invalidOffer
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peer.answer(for: constraints) { description, error in
                if let error { continuation.resume(throwing: error) }
                else if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: RemoteDesktopWebRTCError.answerUnavailable) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(answer) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return answer.sdp
    }

    func addICE(_ candidate: RemoteDesktopICECandidate) async throws {
        let native = try candidate.validatedRTC()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.add(native) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func close() {
        lock.lock()
        active = false
        let channel = inputChannel
        inputChannel = nil
        lock.unlock()
        channel?.delegate = nil
        channel?.close()
        peer.delegate = nil
        peer.close()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed { onClosed("The screen connection ended.") }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        lock.lock()
        let isActive = active
        lock.unlock()
        if isActive { onICE(RemoteDesktopICECandidate(candidate)) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        guard dataChannel.label == "pass.screen.input.v1" else {
            dataChannel.close()
            return
        }
        lock.lock()
        if active && inputChannel == nil {
            inputChannel = dataChannel
            dataChannel.delegate = self
        } else {
            dataChannel.close()
        }
        lock.unlock()
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed { onClosed("The input channel ended.") }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard canControl, !buffer.isBinary, buffer.data.count <= 8_192 else { return }
        lock.lock()
        let permitted = active && inputChannel === dataChannel
        lock.unlock()
        if permitted { onInput(buffer.data) }
    }
}
#endif
