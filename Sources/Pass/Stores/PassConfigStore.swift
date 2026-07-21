import Foundation

/// Project-local settings read from `<project>/pass-config.json`.
/// v1 intentionally keeps the file small and shareable:
///
///     { "urls": ["http://localhost:3000", { "label": "Admin", "url": "admin.example.com" }] }
///
/// URL strings are normalized with the same rules as the embedded browser address bar.
enum PassConfigStore {
    static let fileName = "pass-config.json"

    enum StoreError: LocalizedError, Equatable {
        case invalidConfig
        case invalidURL(String)
        case duplicateURL(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfig:
                return "pass-config.json must be a JSON object with urls as an array."
            case .invalidURL(let message):
                return message
            case .duplicateURL(let url):
                return "URL already exists: \(url)"
            }
        }
    }

    struct URLItem: Codable, Hashable, Sendable, Identifiable {
        var label: String
        var rawURL: String
        var url: URL

        var id: String { url.absoluteString + "|" + label }
    }

    static func urls(projectRoot: String) -> [URLItem] {
        let file = URL(fileURLWithPath: projectRoot).appendingPathComponent(fileName)
        return urls(fileURL: file, fileBase: projectRoot)
    }

    static func exists(projectRoot: String) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: projectRoot).appendingPathComponent(fileName).path
        )
    }

    static func urls(fileURL: URL, fileBase: String? = nil) -> [URLItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(ProjectConfig.self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return decoded.urls.compactMap { entry in
            let raw = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard case .success(let url) = URLNormalizer.normalize(raw, fileBase: fileBase) else { return nil }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return nil }
            let label = entry.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return URLItem(label: label?.isEmpty == false ? label! : defaultLabel(for: url),
                           rawURL: raw, url: url)
        }
    }

    @discardableResult
    static func addURL(projectRoot: String, rawURL: String, label: String? = nil) throws -> URLItem {
        let file = URL(fileURLWithPath: projectRoot).appendingPathComponent(fileName)
        return try addURL(fileURL: file, fileBase: projectRoot, rawURL: rawURL, label: label)
    }

    @discardableResult
    static func addURL(fileURL: URL, fileBase: String? = nil, rawURL: String, label: String? = nil) throws -> URLItem {
        let raw = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: URL
        switch URLNormalizer.normalize(raw, fileBase: fileBase) {
        case .success(let url):
            normalized = url
        case .failure(let failure):
            throw StoreError.invalidURL(failure.message)
        }

        if urls(fileURL: fileURL, fileBase: fileBase).contains(where: { $0.url.absoluteString == normalized.absoluteString }) {
            throw StoreError.duplicateURL(normalized.absoluteString)
        }

        var object = try loadJSONObject(fileURL)
        var entries = try urlEntries(in: object)
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedLabel, !trimmedLabel.isEmpty {
            entries.append(["label": trimmedLabel, "url": raw])
        } else {
            entries.append(raw)
        }
        object["urls"] = entries

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)

        let displayLabel = trimmedLabel?.isEmpty == false ? trimmedLabel! : defaultLabel(for: normalized)
        return URLItem(label: displayLabel, rawURL: raw, url: normalized)
    }

    private static func defaultLabel(for url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent.isEmpty ? "File" : url.lastPathComponent }
        guard let host = url.host else { return url.absoluteString }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    private static func loadJSONObject(_ fileURL: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [:] }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else { throw StoreError.invalidConfig }
        return object
    }

    private static func urlEntries(in object: [String: Any]) throws -> [Any] {
        guard let value = object["urls"] else { return [] }
        guard let entries = value as? [Any] else { throw StoreError.invalidConfig }
        return entries
    }
}

private struct ProjectConfig: Decodable {
    var urls: [ConfigURL]

    private enum CodingKeys: String, CodingKey {
        case urls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urls = try container.decodeIfPresent([ConfigURL].self, forKey: .urls) ?? []
    }
}

private struct ConfigURL: Decodable {
    var label: String?
    var url: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            self.label = nil
            self.url = raw
            return
        }
        let object = try container.decode(Object.self)
        self.label = object.label
        self.url = object.url
    }

    private struct Object: Decodable {
        var label: String?
        var url: String
    }
}
