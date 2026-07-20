import ArgumentParser
import Foundation

struct ExtensionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extension",
        abstract: "Author and validate Pass extensions.",
        subcommands: [Validate.self]
    )
}

extension ExtensionCommand {
    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate extension.json and every referenced resource using the running app.",
            discussion: """
            Uses the same schema, permission catalog, and path-containment checks as Pass. It is \
            read-only: validation never installs, approves, or enables the extension.
            """)

        @Argument(help: "Extension directory (default: current directory).")
        var path: String = "."

        @Flag(help: "Machine-readable output.")
        var json = false

        func run() async throws {
            let absolutePath = absolutized(path)
            let response = await PassClient.post(
                "/cli/extension/validate",
                CLIExtensionValidateRequest(path: absolutePath),
                as: CLIExtensionValidateResponse.self)
            if json { PassClient.printJSON(response) }
            guard response.ok else {
                if !json {
                    for problem in response.problems {
                        FileHandle.standardError.write(Data(("- " + problem + "\n").utf8))
                    }
                }
                PassClient.fail(response.error ?? "extension is not valid", code: PassExit.refused)
            }
            guard !json else { return }
            print("valid extension \(response.id ?? URL(fileURLWithPath: absolutePath).lastPathComponent)")
            if !response.permissions.isEmpty {
                print("permissions: \(response.permissions.joined(separator: ", "))")
            }
        }

        private func absolutized(_ raw: String) -> String {
            let expanded = NSString(string: raw).expandingTildeInPath
            if expanded.hasPrefix("/") { return NSString(string: expanded).standardizingPath }
            return NSString(string: NSString(string: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expanded)).standardizingPath
        }
    }
}
