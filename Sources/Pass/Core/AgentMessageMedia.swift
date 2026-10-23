import Foundation

/// Finds media references in an agent's prose without treating fenced code as a preview request.
enum AgentMessageMedia {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"
    ]

    static func webLinks(in markdown: String) -> [URL] {
        webURLs(in: markdown).filter { !isImage($0) }
    }

    static func bareWebImages(in markdown: String) -> [URL] {
        webURLs(in: markdown).filter(isImage)
    }

    static func bareLocalImages(in markdown: String, relativeTo directory: URL?) -> [URL] {
        let prose = withoutMarkdownImages(withoutFencedCode(markdown))
        var candidates: [String] = []
        let quotedPath = try! NSRegularExpression(pattern: "`(/[^`\\n]+|\\./[^`\\n]+)`")
        let nsProse = prose as NSString
        for match in quotedPath.matches(in: prose, range: NSRange(location: 0, length: nsProse.length)) {
            candidates.append(nsProse.substring(with: match.range(at: 1)))
        }
        candidates += prose.split(whereSeparator: \.isWhitespace)
            .map { cleanPathToken(String($0)) }

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            guard !candidate.contains("://") || candidate.hasPrefix("file://") else { return nil }
            let url: URL
            if candidate.hasPrefix("file://"), let fileURL = URL(string: candidate), fileURL.isFileURL {
                url = fileURL
            } else if candidate.hasPrefix("/") {
                url = URL(fileURLWithPath: candidate)
            } else if (candidate.hasPrefix("./") || candidate.contains("/")), let directory {
                let relativePath = candidate.hasPrefix("./") ? String(candidate.dropFirst(2)) : candidate
                url = directory.appendingPathComponent(relativePath).standardizedFileURL
            } else {
                return nil
            }
            guard isImage(url), seen.insert(url.standardizedFileURL.path).inserted else { return nil }
            return url
        }
    }

    private static func webURLs(in markdown: String) -> [URL] {
        let prose = withoutInlineCode(withoutMarkdownImages(withoutFencedCode(markdown)))
        let expression = try! NSRegularExpression(pattern: #"https?://[^\s<>"'\]\)]+"#,
                                                  options: [.caseInsensitive])
        let nsProse = prose as NSString
        var seen: Set<String> = []
        return expression.matches(in: prose, range: NSRange(location: 0, length: nsProse.length))
            .compactMap { match in
                let candidate = nsProse.substring(with: match.range)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                guard let url = URL(string: candidate),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil,
                      seen.insert(url.absoluteString).inserted else { return nil }
                return url
            }
    }

    private static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func cleanPathToken(_ token: String) -> String {
        let leading = CharacterSet(charactersIn: "`'\"<([{*")
        let trailing = CharacterSet(charactersIn: "`'\">)]}*,;:.!?")
        var result = token
        while let first = result.unicodeScalars.first, leading.contains(first) {
            result.removeFirst()
        }
        while let last = result.unicodeScalars.last, trailing.contains(last) {
            result.removeLast()
        }
        return result
    }

    private static func withoutFencedCode(_ text: String) -> String {
        replacing(#"(?s)```.*?```|~~~.*?~~~"#, in: text)
    }

    private static func withoutInlineCode(_ text: String) -> String {
        replacing(#"`[^`\n]*`"#, in: text)
    }

    private static func withoutMarkdownImages(_ text: String) -> String {
        replacing(#"!\[[^\]]*\]\((?:<[^>]*>|[^)]*)\)"#, in: text)
    }

    private static func replacing(_ pattern: String, in text: String) -> String {
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.stringByReplacingMatches(in: text,
                                                    range: NSRange(location: 0, length: (text as NSString).length),
                                                    withTemplate: " ")
    }
}
