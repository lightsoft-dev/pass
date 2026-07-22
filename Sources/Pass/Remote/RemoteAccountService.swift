import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

enum RemotePublicConfigurationKey {
    static let relayURL = "PassPublicRelayURL"
    static let oidcIssuer = "PassOIDCIssuer"
    static let oidcClientID = "PassOIDCClientID"
    static let oidcAudience = "PassOIDCAudience"
}

enum RemoteAccountState: Equatable, Sendable {
    case unavailable
    case signedOut
    case signingIn
    case registered
    case creatingPairing
    case signingOut
    case failed(String)
}

struct RemotePublicConfiguration: Equatable, Sendable {
    let relayURL: URL
    let issuer: URL
    let clientID: String
    let audience: String
    let redirectURL: URL

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleValues: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> RemotePublicConfiguration? {
        func value(environmentKey: String, bundleKey: String) -> String? {
            let raw = environment[environmentKey] ?? bundleValues[bundleKey] as? String
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        guard
            let relayRaw = value(environmentKey: "PASS_PUBLIC_RELAY_URL", bundleKey: RemotePublicConfigurationKey.relayURL),
            let issuerRaw = value(environmentKey: "PASS_OIDC_ISSUER", bundleKey: RemotePublicConfigurationKey.oidcIssuer),
            let clientID = value(environmentKey: "PASS_OIDC_CLIENT_ID", bundleKey: RemotePublicConfigurationKey.oidcClientID),
            let audience = value(environmentKey: "PASS_OIDC_AUDIENCE", bundleKey: RemotePublicConfigurationKey.oidcAudience),
            let relayURL = URL(string: relayRaw), relayURL.scheme?.lowercased() == "https", relayURL.host != nil,
            let issuer = URL(string: issuerRaw), issuer.scheme?.lowercased() == "https", issuer.host != nil,
            let redirectURL = URL(string: "pass://oauth")
        else { return nil }

        return RemotePublicConfiguration(
            relayURL: relayURL,
            issuer: issuer,
            clientID: clientID,
            audience: audience,
            redirectURL: redirectURL
        )
    }
}

struct RemoteCredentialPair: Codable, Equatable, Sendable {
    let accessToken: String
    let accessExpiresAt: String
    let refreshToken: String
    let refreshExpiresAt: String

    var accessExpiration: Date? { Self.parseDate(accessExpiresAt) }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct RemoteDesktopRegistration: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let relayURL: URL
    let credentials: RemoteCredentialPair
}

struct RemoteUserSession: Codable, Equatable, Sendable {
    let issuer: URL
    let clientID: String
    let audience: String
    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String?
}

struct RemotePairingPayload: Codable, Equatable, Sendable {
    let v: Int
    let relayURL: String
    let desktopID: String
    let pairingID: String
    let pairingSecret: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case v
        case relayURL = "relayUrl"
        case desktopID = "desktopId"
        case pairingID = "pairingId"
        case pairingSecret
        case expiresAt
    }
}

enum RemoteCredentialStore {
    private static let service = "dev.lightsoft.pass.remote"
    private static let desktopAccount = "desktop-registration-v2"
    private static let userAccount = "user-session-v2"

    static func loadDesktopRegistration() throws -> RemoteDesktopRegistration? {
        try load(RemoteDesktopRegistration.self, account: desktopAccount)
    }

    static func saveDesktopRegistration(_ registration: RemoteDesktopRegistration) throws {
        try save(registration, account: desktopAccount)
    }

    static func deleteDesktopRegistration() throws {
        try delete(account: desktopAccount)
    }

    static func loadUserSession() throws -> RemoteUserSession? {
        try load(RemoteUserSession.self, account: userAccount)
    }

    static func saveUserSession(_ session: RemoteUserSession) throws {
        try save(session, account: userAccount)
    }

    static func deleteUserSession() throws {
        try delete(account: userAccount)
    }

    private static func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RemoteAccountError.keychain(status)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RemoteAccountError.keychain(updateStatus)
        }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw RemoteAccountError.keychain(addStatus) }
    }

    private static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteAccountError.keychain(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum RemoteAccountError: Error, LocalizedError {
    case configurationUnavailable
    case invalidDiscovery
    case invalidCallback
    case authorizationFailed(String)
    case invalidServerResponse
    case server(status: Int, message: String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return "Public account authentication is not configured in this build."
        case .invalidDiscovery:
            return "The identity provider returned invalid discovery metadata."
        case .invalidCallback:
            return "The identity provider returned an invalid authorization callback."
        case .authorizationFailed(let message):
            return message
        case .invalidServerResponse:
            return "The remote access server returned an invalid response."
        case .server(_, let message):
            return message
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed (\(status))."
        }
    }
}

@MainActor
final class RemoteAccountService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var authenticationSession: ASWebAuthenticationSession?

    func signInAndRegisterDesktop(
        configuration: RemotePublicConfiguration,
        desktopName: String = Host.current().localizedName ?? "Mac"
    ) async throws -> RemoteDesktopRegistration {
        let discovery = try await discover(configuration.issuer)
        let verifier = Self.randomBase64URL(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomBase64URL(byteCount: 24)
        guard var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw RemoteAccountError.invalidDiscovery
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURL.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "audience", value: configuration.audience),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizationURL = components.url else { throw RemoteAccountError.invalidDiscovery }
        let callbackURL = try await authenticate(at: authorizationURL)
        guard
            let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            callback.scheme == configuration.redirectURL.scheme,
            callback.host == configuration.redirectURL.host,
            callback.queryItems?.first(where: { $0.name == "state" })?.value == state
        else { throw RemoteAccountError.invalidCallback }
        if let message = callback.queryItems?.first(where: { $0.name == "error_description" })?.value
            ?? callback.queryItems?.first(where: { $0.name == "error" })?.value {
            throw RemoteAccountError.authorizationFailed(message)
        }
        guard let code = callback.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw RemoteAccountError.invalidCallback
        }

        let token: OIDCTokenResponse = try await postForm(
            discovery.tokenEndpoint,
            values: [
                "grant_type": "authorization_code",
                "client_id": configuration.clientID,
                "code": code,
                "redirect_uri": configuration.redirectURL.absoluteString,
                "code_verifier": verifier,
            ]
        )
        let userSession = RemoteUserSession(
            issuer: configuration.issuer,
            clientID: configuration.clientID,
            audience: configuration.audience,
            accessToken: token.accessToken,
            accessExpiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 300)),
            refreshToken: token.refreshToken
        )
        try RemoteCredentialStore.saveUserSession(userSession)

        var request = URLRequest(url: configuration.relayURL.appending(path: "v2/desktops"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": desktopName])
        let response: DesktopRegistrationResponse = try await perform(request)
        let registration = RemoteDesktopRegistration(
            id: response.desktop.id,
            name: response.desktop.name,
            relayURL: response.relayURL,
            credentials: response.credentials
        )
        try RemoteCredentialStore.saveDesktopRegistration(registration)
        return registration
    }

    func createPairing() async throws -> (RemotePairingPayload, RemoteDesktopRegistration) {
        let registration = try await refreshDesktopRegistrationIfNeeded()
        var request = URLRequest(url: registration.relayURL.appending(path: "v2/pairings"))
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(registration.credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        let response: PairingResponse = try await perform(request)
        return (response.pairing, registration)
    }

    func refreshDesktopRegistrationIfNeeded(
        margin: TimeInterval = 60
    ) async throws -> RemoteDesktopRegistration {
        guard let registration = try RemoteCredentialStore.loadDesktopRegistration() else {
            throw RemoteAccountError.configurationUnavailable
        }
        if let expiration = registration.credentials.accessExpiration,
           expiration > Date().addingTimeInterval(margin) {
            return registration
        }
        var request = URLRequest(url: registration.relayURL.appending(path: "v2/token/refresh"))
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(registration.credentials.refreshToken)",
            forHTTPHeaderField: "Authorization"
        )
        let response: CredentialResponse = try await perform(request)
        let refreshed = RemoteDesktopRegistration(
            id: registration.id,
            name: registration.name,
            relayURL: registration.relayURL,
            credentials: response.credentials
        )
        try RemoteCredentialStore.saveDesktopRegistration(refreshed)
        return refreshed
    }

    func revokeDesktop(configuration: RemotePublicConfiguration) async throws {
        guard let registration = try RemoteCredentialStore.loadDesktopRegistration(),
              let storedSession = try RemoteCredentialStore.loadUserSession() else {
            try clearLocalCredentials()
            return
        }
        let session = try await freshUserSession(storedSession)
        var request = URLRequest(
            url: configuration.relayURL.appending(path: "v2/desktops/\(registration.id)")
        )
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteAccountError.invalidServerResponse
        }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
            throw RemoteAccountError.server(status: http.statusCode, message: "Could not revoke this Mac.")
        }
        try clearLocalCredentials()
    }

    func clearLocalCredentials() throws {
        try RemoteCredentialStore.deleteDesktopRegistration()
        try RemoteCredentialStore.deleteUserSession()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    }

    private func freshUserSession(_ session: RemoteUserSession) async throws -> RemoteUserSession {
        if session.accessExpiresAt > Date().addingTimeInterval(60) { return session }
        guard let refreshToken = session.refreshToken else {
            throw RemoteAccountError.authorizationFailed("Sign in again to revoke this Mac.")
        }
        let discovery = try await discover(session.issuer)
        let response: OIDCTokenResponse = try await postForm(
            discovery.tokenEndpoint,
            values: [
                "grant_type": "refresh_token",
                "client_id": session.clientID,
                "refresh_token": refreshToken,
                "scope": "openid profile email offline_access",
            ]
        )
        let refreshed = RemoteUserSession(
            issuer: session.issuer,
            clientID: session.clientID,
            audience: session.audience,
            accessToken: response.accessToken,
            accessExpiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 300)),
            refreshToken: response.refreshToken ?? refreshToken
        )
        try RemoteCredentialStore.saveUserSession(refreshed)
        return refreshed
    }

    private func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "pass") { [weak self] callbackURL, error in
                self?.authenticationSession = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: RemoteAccountError.authorizationFailed(
                        error?.localizedDescription ?? "Sign in was cancelled."
                    ))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            if !session.start() {
                authenticationSession = nil
                continuation.resume(throwing: RemoteAccountError.authorizationFailed("Could not open sign in."))
            }
        }
    }

    private func discover(_ issuer: URL) async throws -> OIDCDiscovery {
        let url = issuer.appending(path: ".well-known/openid-configuration")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let discovery = try? JSONDecoder().decode(OIDCDiscovery.self, from: data),
              discovery.issuer == issuer,
              discovery.authorizationEndpoint.scheme == "https",
              discovery.tokenEndpoint.scheme == "https" else {
            throw RemoteAccountError.invalidDiscovery
        }
        return discovery
    }

    private func postForm<Response: Decodable>(
        _ url: URL,
        values: [String: String]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = values.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteAccountError.invalidServerResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            throw RemoteAccountError.server(
                status: http.statusCode,
                message: error?.error.message ?? "Remote access request failed (HTTP \(http.statusCode))."
            )
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RemoteAccountError.invalidServerResponse
        }
        return decoded
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct OIDCDiscovery: Decodable {
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
    }
}

private struct OIDCTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct DesktopRegistrationResponse: Decodable {
    struct Desktop: Decodable {
        let id: String
        let name: String
    }

    let desktop: Desktop
    let credentials: RemoteCredentialPair
    let relayURL: URL

    private enum CodingKeys: String, CodingKey {
        case desktop
        case credentials
        case relayURL = "relayUrl"
    }
}

private struct CredentialResponse: Decodable {
    let credentials: RemoteCredentialPair
}

private struct PairingResponse: Decodable {
    let pairing: RemotePairingPayload
}

private struct APIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }
    let error: APIError
}
