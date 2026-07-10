import Foundation

/// Reads a session's last assistant message straight from Claude Code's own transcript, rather
/// than scraping the terminal. Claude Code stores one JSONL per session under
/// `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`, appending a line per turn.
enum ClaudeTranscript {
    /// Claude Code names a project dir by replacing every '/' and '.' in the absolute cwd with
    /// '-'. e.g. `/Users/zimin/.claude` → `-Users-zimin--claude`.
    static func encodedDir(for cwd: String) -> String {
        String(cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
    }

    /// The agent's last assistant text for a session's cwd, or nil when no transcript/message is
    /// found (unknown cwd, non-Claude agent, message longer than the tail we read).
    static func lastAssistantText(cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encodedDir(for: cwd))", isDirectory: true)
        guard let file = newestJSONL(in: dir), let tail = readTail(file, maxBytes: 256 * 1024) else { return nil }
        return lastAssistantText(inJSONL: tail)
    }

    /// The last non-sidechain assistant turn's text in a JSONL blob. Pure — unit-testable.
    /// Walks lines from the end so it parses only a few, not the whole transcript.
    static func lastAssistantText(inJSONL jsonl: String) -> String? {
        let lines = jsonl.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  (obj["isSidechain"] as? Bool ?? false) == false,
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            let text = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Newest `.jsonl` in a directory (the actively-appended session), by modification time.
    private static func newestJSONL(in dir: URL) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return nil }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .max { a, b in mtime(a, keys) < mtime(b, keys) }
    }

    private static func mtime(_ url: URL, _ keys: [URLResourceKey]) -> Date {
        (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
    }

    /// The last `maxBytes` of a file (enough to contain the final turn) as a String. Reading the
    /// tail keeps this cheap even for multi-megabyte transcripts.
    private static func readTail(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
