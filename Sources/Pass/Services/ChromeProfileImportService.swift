import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

enum BrowserProfileImportPreference {
    static let promptShownKey = "browser.chromeProfileImportPromptShown.v1"
    static let importedKey = "browser.chromeProfileImported.v1"
}

/// A locally installed Chromium profile that can be copied into Pass's WebKit cookie store.
/// `directory` is read-only throughout the import.
struct ChromeProfile: Identifiable, Hashable, Sendable {
    let id: String
    let browserName: String
    let profileName: String
    let directory: URL
    let keychainService: String

    var displayName: String { "\(browserName) · \(profileName)" }
}

struct ChromeCookieImportResult: Sendable {
    let imported: Int
    let skipped: Int
}

struct ChromeCookieExtraction: Sendable {
    let cookies: [ChromeCookieRecord]
    let skipped: Int
}

struct ChromeCookieRecord: Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    let secure: Bool
    let httpOnly: Bool

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path,
            .version: "0",
        ]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

enum ChromeProfileImportError: LocalizedError {
    case cookiesNotFound
    case keychainPasswordNotFound(String)
    case database(String)

    var errorDescription: String? {
        switch self {
        case .cookiesNotFound:
            return "The selected Chrome profile has no cookie database."
        case .keychainPasswordNotFound(let browser):
            return "Could not read \(browser)'s Safe Storage key from Keychain."
        case .database(let message):
            return "Could not read the Chrome cookie database: \(message)"
        }
    }
}

enum ChromeProfileImportService {
    private struct Installation {
        let name: String
        let relativeRoot: String
        let keychainService: String
    }

    private static let installations = [
        Installation(name: "Google Chrome",
                     relativeRoot: "Google/Chrome",
                     keychainService: "Chrome Safe Storage"),
        Installation(name: "Google Chrome Beta",
                     relativeRoot: "Google/Chrome Beta",
                     keychainService: "Chrome Safe Storage"),
        Installation(name: "Chromium",
                     relativeRoot: "Chromium",
                     keychainService: "Chromium Safe Storage"),
    ]

    /// Finds Default/Profile * folders and uses Chrome's Local State names when available.
    static func discoverProfiles(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [ChromeProfile]
    {
        let appSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        var result: [ChromeProfile] = []
        for installation in installations {
            let root = appSupport.appendingPathComponent(installation.relativeRoot, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let names = profileNames(in: root)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for directory in children {
                let folder = directory.lastPathComponent
                guard folder == "Default" || folder.hasPrefix("Profile ") else { continue }
                let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                let profile = ChromeProfile(
                    id: directory.path,
                    browserName: installation.name,
                    profileName: names[folder] ?? (folder == "Default" ? "Default" : folder),
                    directory: directory,
                    keychainService: installation.keychainService
                )
                result.append(profile)
            }
        }
        return result.sorted {
            if $0.browserName == $1.browserName { return $0.profileName < $1.profileName }
            return $0.browserName < $1.browserName
        }
    }

    /// Reads and decrypts Chrome cookies without changing the selected profile.
    static func extractCookies(from profile: ChromeProfile) throws -> ChromeCookieExtraction {
        guard let databaseURL = cookieDatabase(in: profile.directory) else {
            throw ChromeProfileImportError.cookiesNotFound
        }
        let password = try safeStoragePassword(service: profile.keychainService,
                                               browserName: profile.browserName)
        let key = try deriveKey(password: password)

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let database { sqlite3_close(database) }
            throw ChromeProfileImportError.database(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)

        let schemaVersion = cookieSchemaVersion(database)
        let sql = """
            SELECT host_key, name, value, encrypted_value, path, expires_utc,
                   is_secure, is_httponly
            FROM cookies
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ChromeProfileImportError.database(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [ChromeCookieRecord] = []
        var skipped = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let host = text(statement, column: 0)
            let name = text(statement, column: 1)
            let plainValue = text(statement, column: 2)
            let encrypted = blob(statement, column: 3)
            let path = text(statement, column: 4)
            let expires = chromeDate(sqlite3_column_int64(statement, 5))
            let secure = sqlite3_column_int(statement, 6) != 0
            let httpOnly = sqlite3_column_int(statement, 7) != 0

            let value: String?
            if !plainValue.isEmpty {
                value = plainValue
            } else {
                value = decrypt(encrypted, host: host, schemaVersion: schemaVersion, key: key)
            }
            guard !host.isEmpty, !name.isEmpty, let value,
                  expires == nil || expires! > Date() else {
                skipped += 1
                continue
            }
            cookies.append(ChromeCookieRecord(
                name: name, value: value, domain: host, path: path, expires: expires,
                secure: secure, httpOnly: httpOnly
            ))
        }
        let status = sqlite3_errcode(database)
        guard status == SQLITE_OK || status == SQLITE_DONE else {
            throw ChromeProfileImportError.database(String(cString: sqlite3_errmsg(database)))
        }
        return ChromeCookieExtraction(cookies: cookies, skipped: skipped)
    }

    private static func profileNames(in root: URL) -> [String: String] {
        let localState = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (folder, raw) in cache {
            guard let info = raw as? [String: Any] else { continue }
            let preferred = (info["gaia_name"] as? String)?.trimmingCharacters(in: .whitespaces)
            let fallback = (info["name"] as? String)?.trimmingCharacters(in: .whitespaces)
            if let value = [preferred, fallback].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                names[folder] = value
            }
        }
        return names
    }

    private static func cookieDatabase(in directory: URL) -> URL? {
        let candidates = [
            directory.appendingPathComponent("Network/Cookies"),
            directory.appendingPathComponent("Cookies"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func safeStoragePassword(service: String, browserName: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw ChromeProfileImportError.keychainPasswordNotFound(browserName)
        }
        return password
    }

    private static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw ChromeProfileImportError.database("could not derive the cookie encryption key")
        }
        return key
    }

    private static func decrypt(_ encrypted: Data, host: String, schemaVersion: Int, key: Data)
        -> String?
    {
        guard encrypted.count > 3,
              let prefix = String(data: encrypted.prefix(3), encoding: .utf8),
              prefix == "v10" || prefix == "v11" else { return nil }
        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(outputLength..<output.count)

        // Cookie DB schema 24+ authenticates the host by prefixing SHA-256(host_key).
        if schemaVersion >= 24 {
            let expected = Data(SHA256.hash(data: Data(host.utf8)))
            guard output.count >= expected.count, output.prefix(expected.count) == expected else {
                return nil
            }
            output.removeFirst(expected.count)
        }
        return String(data: output, encoding: .utf8)
    }

    private static func cookieSchemaVersion(_ database: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
                                 "SELECT value FROM meta WHERE key = 'version'",
                                 -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(text(statement, column: 0)) ?? 0
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }

    private static func blob(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let raw = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: raw, count: count)
    }

    /// Chrome stores microseconds since 1601-01-01; zero means a session cookie.
    private static func chromeDate(_ raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(raw) / 1_000_000 - 11_644_473_600)
    }
}
