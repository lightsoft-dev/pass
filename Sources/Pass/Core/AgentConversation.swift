import Foundation

/// Semantic conversation content recovered from an agent's terminal transcript.
///
/// Agent TUIs deliberately render different visual grammars. Keeping their strategies separate
/// prevents a marker added for one provider from silently reclassifying another provider's text.
struct AgentConversationBlock: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case user
        case assistant
        case tool
        case output
    }

    let id: String
    var kind: Kind
    var text: String
    var title: String?
}

enum AgentConversationParser {
    fileprivate static let piUserStart = "__PASS_PI_USER_START__"
    fileprivate static let piUserEnd = "__PASS_PI_USER_END__"
    fileprivate static let piUserFinal = "__PASS_PI_USER_FINAL__"

    static func parse(_ pane: String, agent: AgentKind) -> [AgentConversationBlock] {
        let lines = normalizedLines(pane)
        let parsed: [Draft]
        switch agent {
        case .claude:
            parsed = ClaudeStrategy.parse(lines)
        case .codex:
            parsed = CodexStrategy.parse(lines)
        case .pi:
            parsed = PiStrategy.parse(lines)
        case .shell, .generic:
            parsed = ShellStrategy.parse(lines)
        }
        return Array(parsed.suffix(120)).enumerated().map { index, block in
            AgentConversationBlock(
                id: stableID(for: block, index: index),
                kind: block.kind,
                text: block.text,
                title: block.title
            )
        }
    }

    static func stripTerminalControl(_ value: String) -> String {
        var result = value
        let patterns = [
            #"\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)"#,
            #"\u001B\[[0-?]*[ -/]*[@-~]"#,
            #"\u001B[@-_]"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
            .replacingOccurrences(of: "\r", with: "")
            .unicodeScalars
            .filter { scalar in
                let value = scalar.value
                return value == 0x09 || value == 0x0a || value >= 0x20 && value != 0x7f
            }
            .map(String.init)
            .joined()
    }

    fileprivate struct Line {
        let raw: String
        let value: String
        let indented: Bool
    }

    fileprivate struct Draft {
        var kind: AgentConversationBlock.Kind
        var text: String
        var title: String?
    }

    fileprivate static func append(
        _ blocks: inout [Draft],
        _ kind: AgentConversationBlock.Kind,
        _ text: String,
        title: String? = nil
    ) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || title != nil else { return }
        blocks.append(Draft(kind: kind, text: text, title: title))
    }

    fileprivate static func continueLast(
        _ blocks: inout [Draft],
        with value: String,
        preservingLine: Bool
    ) {
        guard !blocks.isEmpty, !value.isEmpty else { return }
        let last = blocks.count - 1
        let current = blocks[last].text
        let markdownLine = value.range(
            of: #"^(```|\| |[-*] |\d+[.)] |#{1,4} )"#,
            options: .regularExpression
        ) != nil
        if current.isEmpty {
            blocks[last].text = value
        } else if preservingLine || markdownLine || current.hasSuffix("|") {
            blocks[last].text += "\n" + value
        } else {
            blocks[last].text += " " + value
        }
    }

    private static func normalizedLines(_ pane: String) -> [Line] {
        // Pi wraps user-message rows in OSC 133 semantic prompt zones. Preserve those three
        // boundaries before removing the rest of the terminal controls; unlike color-based
        // inference, this remains stable across every Pi theme.
        let semanticPane = String(pane.suffix(512 * 1024))
            .replacingOccurrences(of: "\u{1b}]133;A\u{07}", with: piUserStart)
            .replacingOccurrences(of: "\u{1b}]133;B\u{07}", with: piUserEnd)
            .replacingOccurrences(of: "\u{1b}]133;C\u{07}", with: piUserFinal)
        return stripTerminalControl(semanticPane)
            .components(separatedBy: "\n")
            .map { original in
                let trailingTrimmed = original.replacingOccurrences(
                    of: #"[ \t]+$"#,
                    with: "",
                    options: .regularExpression
                )
                let unframed = trailingTrimmed
                    .replacingOccurrences(of: #"^\s*[│┃]\s?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s?[│┃]\s*$"#, with: "", options: .regularExpression)
                return Line(
                    raw: unframed,
                    value: unframed.trimmingCharacters(in: .whitespaces),
                    indented: unframed.range(of: #"^\s{2,}"#, options: .regularExpression) != nil
                )
            }
    }

    fileprivate static func isChrome(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return true }
        let decorations = CharacterSet(charactersIn: "─━│┃┌┐└┘╭╮╰╯═╪┬┴├┤┼…·╌╍ ")
        if value.unicodeScalars.allSatisfy(decorations.contains) { return true }
        if ["❯", "›", ">"].contains(value) { return true }
        let lower = value.lowercased()
        return [
            "shift+tab to cycle", "bypass permissions", "esc to interrupt",
            "for shortcuts", "to edit in", "context left", "context used",
            "tokens used", "ctrl+c to cancel",
        ].contains { lower.contains($0) }
    }

    fileprivate static func isToolTitle(_ value: String) -> Bool {
        let leads = [
            "bash", "read", "write", "edit", "update", "search", "glob", "grep", "task",
            "webfetch", "websearch", "notebookedit", "skill", "tool", "ran", "explored",
            "edited", "searched", "called", "wrote", "updated", "added", "deleted", "viewed",
            "listed", "checked", "waiting",
        ]
        let lower = value.lowercased()
        return leads.contains { lower == $0 || lower.hasPrefix($0 + "(") || lower.hasPrefix($0 + " ") }
    }

    private static func stableID(for block: Draft, index: Int) -> String {
        let stableText = block.kind == .tool ? "" : String(block.text.prefix(96))
        let input = "\(block.kind)\u{0}\(block.title ?? "")\u{0}\(stableText)"
        var hash: UInt32 = 2_166_136_261
        for byte in input.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return "\(block.kind)-\(index)-\(String(hash, radix: 16))"
    }
}

private enum ClaudeStrategy {
    static func parse(_ lines: [AgentConversationParser.Line]) -> [AgentConversationParser.Draft] {
        var blocks: [AgentConversationParser.Draft] = []
        for line in lines where !AgentConversationParser.isChrome(line.raw) {
            if let content = line.value.firstMatch(#"^(?:❯|›|>)\s+(.+)$"#) {
                AgentConversationParser.append(&blocks, .user, content)
            } else if let content = line.value.firstMatch(#"^(?:⏺|●)\s*(.*)$"#) {
                if AgentConversationParser.isToolTitle(content) {
                    AgentConversationParser.append(&blocks, .tool, "", title: content)
                } else {
                    AgentConversationParser.append(&blocks, .assistant, content)
                }
            } else if let result = line.value.firstMatch(#"^(?:⎿|└(?:─)?|↳)\s*(.*)$"#) {
                if blocks.last?.kind == .tool {
                    AgentConversationParser.continueLast(&blocks, with: result, preservingLine: true)
                } else {
                    AgentConversationParser.append(&blocks, .output, result)
                }
            } else if line.indented, blocks.last != nil {
                AgentConversationParser.continueLast(
                    &blocks,
                    with: line.value,
                    preservingLine: blocks.last?.kind == .tool || blocks.last?.kind == .output
                )
            } else if blocks.last?.kind == .tool {
                AgentConversationParser.continueLast(&blocks, with: line.value, preservingLine: true)
            }
        }
        return blocks
    }
}

private enum CodexStrategy {
    static func parse(_ lines: [AgentConversationParser.Line]) -> [AgentConversationParser.Draft] {
        var blocks: [AgentConversationParser.Draft] = []
        for line in lines where !AgentConversationParser.isChrome(line.raw) {
            if let content = line.value.firstMatch(#"^(?:›|>)\s+(.+)$"#) {
                AgentConversationParser.append(&blocks, .user, content)
            } else if let content = line.value.firstMatch(#"^[•●]\s*(.*)$"#) {
                if AgentConversationParser.isToolTitle(content) {
                    AgentConversationParser.append(&blocks, .tool, "", title: content)
                } else {
                    AgentConversationParser.append(&blocks, .assistant, content)
                }
            } else if let result = line.value.firstMatch(#"^(?:└(?:─)?|↳)\s*(.*)$"#) {
                if blocks.last?.kind == .tool {
                    AgentConversationParser.continueLast(&blocks, with: result, preservingLine: true)
                } else {
                    AgentConversationParser.append(&blocks, .output, result)
                }
            } else if line.indented, blocks.last != nil {
                AgentConversationParser.continueLast(
                    &blocks,
                    with: line.value,
                    preservingLine: blocks.last?.kind == .tool || blocks.last?.kind == .output
                )
            } else if blocks.last?.kind == .tool {
                AgentConversationParser.continueLast(&blocks, with: line.value, preservingLine: true)
            }
        }
        return blocks
    }
}

private enum PiStrategy {
    /// Pi uses OSC 133 semantic zones around user messages and terminal styling elsewhere,
    /// rather than Claude/Codex's fixed bullets. Role labels remain supported for extensions.
    static func parse(_ lines: [AgentConversationParser.Line]) -> [AgentConversationParser.Draft] {
        var blocks: [AgentConversationParser.Draft] = []
        var insideUserMessage = false
        for line in lines where !AgentConversationParser.isChrome(line.raw) {
            let startsUser = line.value.contains(AgentConversationParser.piUserStart)
            let endsUser = line.value.contains(AgentConversationParser.piUserEnd)
            let semanticContent = line.value
                .replacingOccurrences(of: AgentConversationParser.piUserStart, with: "")
                .replacingOccurrences(of: AgentConversationParser.piUserEnd, with: "")
                .replacingOccurrences(of: AgentConversationParser.piUserFinal, with: "")
                .trimmingCharacters(in: .whitespaces)

            if startsUser {
                AgentConversationParser.append(&blocks, .user, semanticContent)
                insideUserMessage = !endsUser
            } else if insideUserMessage {
                if blocks.last?.kind == .user {
                    AgentConversationParser.continueLast(
                        &blocks,
                        with: semanticContent,
                        preservingLine: true
                    )
                }
                if endsUser { insideUserMessage = false }
            } else if let content = line.value.firstMatch(#"^(?:User|You|>)\s*[:>]\s*(.+)$"#, caseInsensitive: true) {
                AgentConversationParser.append(&blocks, .user, content)
            } else if let content = line.value.firstMatch(#"^(?:Assistant|Pi)\s*:\s*(.*)$"#, caseInsensitive: true) {
                AgentConversationParser.append(&blocks, .assistant, content)
            } else if let title = line.value.firstMatch(#"^(?:Tool|Running|Ran)\s*:\s*(.+)$"#, caseInsensitive: true) {
                AgentConversationParser.append(&blocks, .tool, "", title: title)
            } else if AgentConversationParser.isToolTitle(line.value) {
                AgentConversationParser.append(&blocks, .tool, "", title: line.value)
            } else if let result = line.value.firstMatch(#"^(?:└(?:─)?|↳)\s*(.*)$"#) {
                if blocks.last?.kind == .tool {
                    AgentConversationParser.continueLast(&blocks, with: result, preservingLine: true)
                } else {
                    AgentConversationParser.append(&blocks, .output, result)
                }
            } else if line.indented, blocks.last != nil {
                AgentConversationParser.continueLast(&blocks, with: line.value, preservingLine: true)
            } else if blocks.last?.kind == .assistant || blocks.last?.kind == .tool {
                AgentConversationParser.continueLast(&blocks, with: line.value, preservingLine: true)
            } else if blocks.last?.kind == .user {
                AgentConversationParser.append(&blocks, .assistant, line.value)
            }
        }
        return blocks
    }
}

private enum ShellStrategy {
    static func parse(_ lines: [AgentConversationParser.Line]) -> [AgentConversationParser.Draft] {
        let output = lines
            .filter { !AgentConversationParser.isChrome($0.raw) }
            .map(\.raw)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return [] }
        return [.init(kind: .output, text: output, title: "Terminal output")]
    }
}

private extension String {
    func firstMatch(_ pattern: String, caseInsensitive: Bool = false) -> String? {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range), match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[capture]).trimmingCharacters(in: .whitespaces)
    }
}
