import AppKit
import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter. Ad-hoc signing is sufficient for delivery
/// as long as the app runs from a bundle with a stable CFBundleIdentifier (FINDINGS/plan R6).
struct NotificationService: Sendable {
    private var center: UNUserNotificationCenter { .current() }

    /// Request authorization and return the resulting status. `.denied` means macOS won't
    /// show banners until the user enables them in System Settings › Notifications › Pass
    /// (the menu-bar badge remains the notification-independent attention channel).
    @discardableResult
    func requestAuthorization() async -> UNAuthorizationStatus {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.app.error("notification authorization request failed: \(error.localizedDescription, privacy: .public)")
        }
        let status = await center.notificationSettings().authorizationStatus
        Log.app.info("notification authorization status=\(status.rawValue) (0=notDetermined 1=denied 2=authorized 3=provisional)")
        return status
    }

    /// Post (or replace) a notification for a session. identifier = "<session>:<kind>" so a
    /// re-fired event updates the existing banner instead of stacking.
    func notify(session: String, kind: String, title: String, body: String, sound: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        content.userInfo = ["session": session, "kind": kind]
        content.threadIdentifier = session

        let request = UNNotificationRequest(
            identifier: "\(session):\(kind)",
            content: content,
            trigger: nil // deliver immediately
        )
        do {
            try await center.add(request)
        } catch {
            Log.app.error("notify failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove any delivered/pending notifications for a session (e.g. when its item is opened).
    func clear(session: String, kinds: [String]) {
        let ids = kinds.map { "\(session):\($0)" }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Open System Settings at the Notifications pane so the user can enable pass.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
