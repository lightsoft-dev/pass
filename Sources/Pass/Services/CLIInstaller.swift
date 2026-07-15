import Foundation

/// Keeps the stable passcli path (`~/.pass/bin/passcli`) pointing at the helper inside the
/// CURRENTLY-running bundle. Sessions get `$PASS_CLI=<symlink>` and the SessionStart
/// advertise hook runs the symlink — refreshing on every launch means the app can move (or
/// run from a build directory) without breaking either (BROWSER.md §5.2).
enum CLIInstaller {
    /// The passcli binary inside this app bundle (Contents/MacOS/passcli), if built in.
    static var bundledBinaryPath: String? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "passcli"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    /// The symlink exists and points at an executable (Settings status row).
    static var isLinked: Bool {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: PassConfig.cliSymlinkPath) else {
            return false
        }
        return fm.isExecutableFile(atPath: dest)
    }

    /// Point ~/.pass/bin/passcli at this bundle's helper. Idempotent; safe to call each launch.
    @discardableResult
    static func refreshSymlink() -> Bool {
        guard let target = bundledBinaryPath else {
            Log.app.error("passcli missing from bundle — symlink not refreshed")
            return false
        }
        let fm = FileManager.default
        let link = PassConfig.cliSymlinkPath
        do {
            try fm.createDirectory(atPath: PassConfig.cliBinDir, withIntermediateDirectories: true)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
                if existing == target { return true }
                try fm.removeItem(atPath: link)
            } else if fm.fileExists(atPath: link) {
                try fm.removeItem(atPath: link) // a stale regular file in our spot
            }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
            Log.app.info("passcli symlink → \(target, privacy: .public)")
            return true
        } catch {
            Log.app.error("passcli symlink failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
