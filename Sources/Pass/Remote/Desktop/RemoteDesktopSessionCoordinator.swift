#if os(macOS)
import AppKit
import Foundation

enum RemoteDesktopPreferenceKey {
    static let enabled = "remoteDesktop.enabled"
}

/// One approved screen lease for the authenticated desktop relay socket. Screen pixels and
/// input never enter the relay: this coordinator only exchanges WebRTC signaling messages.
@MainActor
final class RemoteDesktopSessionCoordinator {
    private final class Session {
        let id: String
        let controllerID: String
        let requestedControl: Bool
        let display: RemoteDesktopDisplay
        var canControl = false
        var peer: RemoteDesktopWebRTCPeer?
        var captureReady = false
        var pendingOffer: String?
        var offerStarted = false
        var remoteDescriptionSet = false
        var pendingICE: [RemoteDesktopICECandidate] = []
        var expiryTask: Task<Void, Never>?

        init(id: String, controllerID: String, requestedControl: Bool, display: RemoteDesktopDisplay) {
            self.id = id
            self.controllerID = controllerID
            self.requestedControl = requestedControl
            self.display = display
        }
    }

    private let host: RemoteDesktopHost
    private let send: (Data) async throws -> Void
    private let statusChanged: (String, String?) -> Void
    private var session: Session?
    private var pendingRequestID: String?
    private var approvalAlert: NSAlert?

    init(
        host: RemoteDesktopHost,
        send: @escaping (Data) async throws -> Void,
        statusChanged: @escaping (String, String?) -> Void
    ) {
        self.host = host
        self.send = send
        self.statusChanged = statusChanged
        host.onCaptureFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                await self?.stop(notifyRelay: true, status: message)
            }
        }
    }

    var isActive: Bool { session != nil }

    func receive(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String,
              let payload = root["payload"] as? [String: Any],
              let sessionID = payload["sessionId"] as? String,
              !sessionID.isEmpty else { return }

        switch type {
        case "desktop.screen.requested":
            guard let controllerID = payload["deviceId"] as? String,
                  !controllerID.isEmpty,
                  let requestedControl = payload["requestedControl"] as? Bool,
                  let expiry = Self.date(payload["expiresAt"]) else { return }
            guard pendingRequestID == nil else {
                Task { try? await self.sendSignal("desktop.screen.deny", payload: ["sessionId": sessionID]) }
                return
            }
            pendingRequestID = sessionID
            Task { await self.handleRequest(
                id: sessionID, controllerID: controllerID,
                requestedControl: requestedControl, expiresAt: expiry
            ) }

        case "desktop.screen.approved":
            guard let current = session, current.id == sessionID,
                  let canControl = payload["canControl"] as? Bool,
                  let expiry = Self.date(payload["expiresAt"]),
                  let rawServers = payload["iceServers"],
                  let serverData = try? JSONSerialization.data(withJSONObject: rawServers),
                  let servers = try? JSONDecoder().decode([RemoteDesktopICEServer].self, from: serverData)
            else { return }
            Task { await self.handleApproved(
                current, canControl: canControl, expiresAt: expiry, iceServers: servers
            ) }

        case "desktop.screen.offer":
            guard let current = session, current.id == sessionID,
                  let sdp = payload["sdp"] as? String else { return }
            if current.captureReady {
                Task { await self.handleOffer(current, sdp: sdp) }
            } else if current.pendingOffer == nil {
                current.pendingOffer = sdp
            }

        case "desktop.screen.ice":
            guard let current = session, current.id == sessionID,
                  let rawCandidate = payload["candidate"],
                  let candidateData = try? JSONSerialization.data(withJSONObject: rawCandidate),
                  let candidate = try? JSONDecoder().decode(RemoteDesktopICECandidate.self, from: candidateData)
            else { return }
            if current.remoteDescriptionSet, let peer = current.peer {
                Task { try? await peer.addICE(candidate) }
            } else if current.pendingICE.count < 128 {
                current.pendingICE.append(candidate)
            }

        case "desktop.screen.close":
            if pendingRequestID == sessionID {
                pendingRequestID = nil
                approvalAlert?.window.close()
                approvalAlert = nil
                statusChanged(host.isEnabled ? "Ready" : "Off", nil)
                return
            }
            guard session?.id == sessionID else { return }
            Task { await self.stop(notifyRelay: false) }

        default:
            break
        }
    }

    private func handleRequest(
        id: String, controllerID: String, requestedControl: Bool, expiresAt: Date
    ) async {
        guard pendingRequestID == id, session == nil, host.isEnabled, expiresAt > Date() else {
            if pendingRequestID == id { pendingRequestID = nil }
            try? await sendSignal("desktop.screen.deny", payload: ["sessionId": id])
            return
        }
        guard host.hasScreenRecordingAccess else {
            pendingRequestID = nil
            statusChanged("Screen Recording permission is required", nil)
            try? await sendSignal("desktop.screen.deny", payload: ["sessionId": id])
            return
        }
        let displays: [RemoteDesktopDisplay]
        do {
            displays = try await host.availableDisplays()
        } catch {
            pendingRequestID = nil
            statusChanged(error.localizedDescription, nil)
            try? await sendSignal("desktop.screen.deny", payload: ["sessionId": id])
            return
        }
        guard pendingRequestID == id, !displays.isEmpty, expiresAt > Date() else {
            if pendingRequestID == id { pendingRequestID = nil }
            try? await sendSignal("desktop.screen.deny", payload: ["sessionId": id])
            return
        }

        statusChanged(requestedControl ? "Control approval requested" : "Screen approval requested", controllerID)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = requestedControl ? "Allow remote control of this Mac?" : "Share this Mac's screen?"
        alert.informativeText = "Device \(controllerID) requested access. Screen sharing stops after 15 minutes or when you disconnect it."
        alert.addButton(withTitle: requestedControl ? "Allow Control" : "Share Screen")
        if requestedControl { alert.addButton(withTitle: "View Only") }
        alert.addButton(withTitle: "Deny")
        let displayPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        for (index, display) in displays.enumerated() {
            let name = display.id == CGMainDisplayID() ? "Main display" : "Display \(index + 1)"
            displayPicker.addItem(withTitle: "\(name) · \(display.width) × \(display.height)")
        }
        if let mainIndex = displays.firstIndex(where: { $0.id == CGMainDisplayID() }) {
            displayPicker.selectItem(at: mainIndex)
        }
        alert.accessoryView = displayPicker
        NSApp.activate(ignoringOtherApps: true)
        approvalAlert = alert
        let response = alert.runModal()
        approvalAlert = nil
        guard pendingRequestID == id, session == nil, expiresAt > Date() else {
            if pendingRequestID == id { pendingRequestID = nil }
            try? await sendSignal("desktop.screen.deny", payload: ["sessionId": id])
            return
        }
        pendingRequestID = nil
        let denied = requestedControl
            ? response != .alertFirstButtonReturn && response != .alertSecondButtonReturn
            : response != .alertFirstButtonReturn
        guard !denied else {
            statusChanged(host.isEnabled ? "Ready" : "Off", nil)
            try? await sendSignal("desktop.screen.deny", payload: ["sessionId": id])
            return
        }
        let displayIndex = max(0, min(displays.count - 1, displayPicker.indexOfSelectedItem))
        let allowControl = requestedControl && response == .alertFirstButtonReturn && host.hasAccessibilityAccess
        if requestedControl && response == .alertFirstButtonReturn && !host.hasAccessibilityAccess {
            statusChanged("Accessibility permission is needed for control; allowing view only", controllerID)
        }
        let current = Session(
            id: id, controllerID: controllerID, requestedControl: requestedControl,
            display: displays[displayIndex]
        )
        do {
            try host.approve(controllerID: controllerID, expiresAt: expiresAt)
            session = current
            try await sendSignal("desktop.screen.approve", payload: [
                "sessionId": id, "allowControl": allowControl,
            ])
            guard session === current else { return }
            statusChanged("Preparing screen connection", controllerID)
        } catch {
            guard session === current else { return }
            session = nil
            await host.revoke(controllerID: controllerID)
            guard session == nil, pendingRequestID == nil else { return }
            statusChanged(error.localizedDescription, nil)
            try? await sendSignal("desktop.screen.deny", payload: ["sessionId": id])
        }
    }

    private func handleApproved(
        _ current: Session, canControl: Bool, expiresAt: Date,
        iceServers: [RemoteDesktopICEServer]
    ) async {
        guard session === current, expiresAt > Date() else { return }
        do {
            try host.approve(controllerID: current.controllerID, expiresAt: expiresAt)
            current.canControl = canControl
            let peer = try RemoteDesktopWebRTCPeer(
                iceServers: iceServers,
                canControl: canControl,
                onICE: { [weak self, weak current] candidate in
                    Task { @MainActor [weak self, weak current] in
                        guard let self, let current, self.session === current else { return }
                        try? await self.sendSignal("desktop.screen.ice", payload: [
                            "sessionId": current.id,
                            "candidate": [
                                "candidate": candidate.candidate,
                                "sdpMid": candidate.sdpMid.map { $0 as Any } ?? NSNull(),
                                "sdpMLineIndex": candidate.sdpMLineIndex,
                            ],
                        ])
                    }
                },
                onInput: { [weak self, weak current] data in
                    Task { @MainActor [weak self, weak current] in
                        guard let self, let current, self.session === current,
                              current.canControl,
                              let input = try? JSONDecoder().decode(RemoteDesktopInputEvent.self, from: data)
                        else { return }
                        try? self.host.inject(input, controllerID: current.controllerID)
                    }
                },
                onClosed: { [weak self, weak current] message in
                    Task { @MainActor [weak self, weak current] in
                        guard let self, let current, self.session === current else { return }
                        await self.stop(notifyRelay: true, status: message)
                    }
                }
            )
            current.peer = peer
            try await host.startCapture(
                controllerID: current.controllerID, displayID: current.display.id,
                onFrame: { [weak peer] frame in peer?.push(frame) }
            )
            guard session === current else { return }
            current.captureReady = true
            current.expiryTask = Task { [weak self, weak current] in
                let interval = max(0, expiresAt.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, let current,
                      self.session === current else { return }
                await self.stop(notifyRelay: true, status: "Screen sharing time expired")
            }
            statusChanged(canControl ? "Connecting · control approved" : "Connecting · view only", current.controllerID)
            if let offer = current.pendingOffer {
                current.pendingOffer = nil
                await handleOffer(current, sdp: offer)
            }
        } catch {
            guard session === current else { return }
            await stop(notifyRelay: true, status: error.localizedDescription)
        }
    }

    private func handleOffer(_ current: Session, sdp: String) async {
        guard session === current, current.captureReady, !current.offerStarted,
              let peer = current.peer else { return }
        current.offerStarted = true
        do {
            let answer = try await peer.acceptOffer(sdp)
            guard session === current else { return }
            current.remoteDescriptionSet = true
            try await sendSignal("desktop.screen.answer", payload: [
                "sessionId": current.id,
                "sdp": answer,
                "displayWidth": current.display.width,
                "displayHeight": current.display.height,
            ])
            guard session === current else { return }
            let candidates = current.pendingICE
            current.pendingICE.removeAll()
            for candidate in candidates { try? await peer.addICE(candidate) }
            guard session === current else { return }
            statusChanged(current.canControl ? "Screen sharing · control" : "Screen sharing · view only", current.controllerID)
        } catch {
            guard session === current else { return }
            await stop(notifyRelay: true, status: error.localizedDescription)
        }
    }

    func stop(notifyRelay: Bool, status: String? = nil) async {
        let pending = pendingRequestID
        let current = session
        guard pending != nil || current != nil else {
            if let status { statusChanged(status, nil) }
            return
        }
        pendingRequestID = nil
        approvalAlert?.window.close()
        approvalAlert = nil
        session = nil
        current?.expiryTask?.cancel()
        current?.peer?.close()
        statusChanged(status ?? (host.isEnabled ? "Ready" : "Off"), nil)
        if let current { await host.revoke(controllerID: current.controllerID) }
        if notifyRelay {
            if let pending {
                try? await sendSignal("desktop.screen.deny", payload: ["sessionId": pending])
            }
            if let current {
                try? await sendSignal("desktop.screen.close", payload: ["sessionId": current.id])
            }
        }
    }

    private func sendSignal(_ type: String, payload: [String: Any]) async throws {
        let envelope: [String: Any] = [
            "version": 1,
            "id": "evt_\(UUID().uuidString.lowercased())",
            "type": type,
            "sentAt": ISO8601DateFormatter().string(from: Date()),
            "payload": payload,
        ]
        try await send(JSONSerialization.data(withJSONObject: envelope))
    }

    private static func date(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }
}
#endif
