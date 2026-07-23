import AppKit
import UniformTypeIdentifiers

/// Directory picker for registering project sync sources. Allows multiple selection so the user
/// can pick several project folders or the parent directories that collect them.
enum ProjectPicker {
    @MainActor
    static func pick() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose directories that contain the projects Pass should sync"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }

    /// Pick a single directory (for "New session…").
    @MainActor
    static func pickOne(prompt: String, message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Choose where to write a backup archive. Returns the destination URL, or nil if cancelled.
    @MainActor
    static func saveBackupPanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.gzip]
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to save the Pass backup"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
