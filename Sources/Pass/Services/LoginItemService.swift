import Foundation
import ServiceManagement

/// Launch pass at login via SMAppService (macOS 13+, works for non-sandboxed apps).
enum LoginItemService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            Log.app.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
