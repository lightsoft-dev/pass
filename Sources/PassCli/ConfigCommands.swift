import ArgumentParser
import Foundation

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Edit project-local pass-config.json settings.",
        subcommands: [URLConfig.self]
    )
}

struct URLConfig: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "url",
        abstract: "Manage URLs shown in this session's URL bar.",
        subcommands: [Add.self]
    )
}

extension URLConfig {
    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a URL to this project's pass-config.json.",
            discussion: """
            Saves the URL into pass-config.json for the target session's project. The Pass \
            UI reloads the URL bar immediately. URL forms match browser open: localhost:3000, \
            3000, https://example.com, or a project-relative file path.
            """
        )

        @Argument(help: "The URL to save.")
        var url: String

        @Option(help: "Display label in the URL bar.")
        var label: String?

        @OptionGroup var target: SessionOption

        @Flag(help: "Machine-readable output.")
        var json = false

        func run() async throws {
            let session = target.resolved()
            let response = await PassClient.post(
                "/cli/config/url/add",
                CLIConfigURLAddRequest(session: session, url: url, label: label),
                as: CLIConfigURLAddResponse.self
            )
            if json { PassClient.printJSON(response) }
            guard response.ok else {
                PassClient.fail("config url add failed: \(response.error ?? "unknown error")",
                                code: PassExit.refused)
            }
            if !json {
                let displayLabel = response.label.map { " as \($0)" } ?? ""
                print("added \(response.resolvedURL ?? url)\(displayLabel) · session \(session)")
            }
        }
    }
}
