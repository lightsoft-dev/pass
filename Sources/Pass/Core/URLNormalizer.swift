import Foundation

/// Turns what a human (⌘L) or an agent (`passcli browser open`) typed into a loadable URL,
/// per the BROWSER.md §7.1 table. Only http/https/file ever come out; every other scheme is
/// refused here (the single choke point for both the address bar and the /cli endpoint).
/// Pure: file existence is injected so tests never touch the real filesystem.
enum URLNormalizer {
    enum Failure: Error, Equatable {
        case empty
        case schemeNotAllowed(String)
        case unparseable
        case invalidPort
        case relativeNeedsBase          // "./x" with no base directory to resolve against
        case fileNotFound(String)

        /// Short human/agent-readable reason (returned in CLI errors and shown under ⌘L).
        var message: String {
            switch self {
            case .empty: return "empty URL"
            case .schemeNotAllowed(let s): return "scheme not allowed: \(s):"
            case .unparseable: return "not a valid URL"
            case .invalidPort: return "not a valid port"
            case .relativeNeedsBase: return "relative path needs a working directory"
            case .fileNotFound(let p): return "file not found: \(p)"
            }
        }
    }

    /// `fileBase`: directory for resolving relative paths (the CLI sends absolute paths, but
    /// the server also resolves against the session's cwd as a fallback).
    static func normalize(
        _ raw: String,
        fileBase: String? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Result<URL, Failure> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .failure(.empty) }
        let lower = s.lowercased()

        // Explicitly-allowed schemes pass through untouched.
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: s), let host = url.host, !host.isEmpty else {
                return .failure(.unparseable)
            }
            return .success(url)
        }
        if lower.hasPrefix("file://") {
            guard let url = URL(string: s), url.isFileURL else { return .failure(.unparseable) }
            return .success(url)
        }

        // Any other explicit scheme is refused (javascript:, data:, mailto:, vscode://…).
        // "localhost:5173" and "foo.com:8080" are host:port, not schemes: a dotted head or a
        // digit right after the colon keeps them flowing.
        if s.contains("://") {
            return .failure(.schemeNotAllowed(String(s.prefix { $0 != ":" }).lowercased()))
        }
        if let colon = s.firstIndex(of: ":") {
            let head = String(s[..<colon]).lowercased()
            let after = s.index(after: colon)
            let next: Character = after < s.endIndex ? s[after] : " "
            let schemeLike = !head.isEmpty
                && head.first!.isLetter
                && head.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
            if schemeLike && !head.contains(".") && !isDigit(next) {
                return .failure(.schemeNotAllowed(head))
            }
        }

        // Bare port shortcuts → the local dev server ("5173", ":5173", ":5173/admin").
        if s.hasPrefix(":") {
            let rest = s.dropFirst()
            let digits = rest.prefix(while: isDigit)
            guard !digits.isEmpty, let port = Int(digits), (1...65535).contains(port) else {
                return .failure(.invalidPort)
            }
            return parse("http://localhost" + s)
        }
        if s.allSatisfy(isDigit) {
            guard let port = Int(s), (1...65535).contains(port) else { return .failure(.invalidPort) }
            return parse("http://localhost:\(s)")
        }

        // Local file paths → file:// (existence checked; agents preview built HTML this way).
        if s.hasPrefix("/") || s.hasPrefix("./") || s.hasPrefix("../") || s.hasPrefix("~") {
            var path = NSString(string: s).expandingTildeInPath
            if !path.hasPrefix("/") {
                guard let fileBase, !fileBase.isEmpty else { return .failure(.relativeNeedsBase) }
                path = NSString(string: fileBase).appendingPathComponent(path)
            }
            path = NSString(string: path).standardizingPath
            guard fileExists(path) else { return .failure(.fileNotFound(path)) }
            return .success(URL(fileURLWithPath: path))
        }

        // Bare host[:port][/path] — the localhost family stays http, the web gets https.
        let localPrefixes = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"]
        let isLocal = localPrefixes.contains { lower == $0 || lower.hasPrefix($0 + ":") || lower.hasPrefix($0 + "/") }
        return parse("\(isLocal ? "http" : "https")://\(s)")
    }

    private static func parse(_ s: String) -> Result<URL, Failure> {
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else {
            return .failure(.unparseable)
        }
        return .success(url)
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
}
