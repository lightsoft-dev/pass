import Foundation

struct MarketplaceOwner: Codable, Hashable, Sendable {
    var id: String
    var displayName: String?
}

struct MarketplaceExtension: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var repositoryURL: String
    var name: String
    var summary: String
    var description: String?
    var category: String?
    var tags: [String]
    var version: String
    var manifest: ExtensionManifest
    var owner: MarketplaceOwner
    var installCount: Int
    var reportCount: Int?
    var isOwner: Bool
    var canModerate: Bool
    var isHidden: Bool
    var createdAt: String
    var updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, description, category, tags, version, manifest, owner
        case repositoryURL = "repositoryUrl"
        case installCount, reportCount, isOwner, canModerate, isHidden, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        repositoryURL = try values.decode(String.self, forKey: .repositoryURL)
        name = try values.decode(String.self, forKey: .name)
        summary = try values.decode(String.self, forKey: .summary)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        category = try values.decodeIfPresent(String.self, forKey: .category)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        version = try values.decode(String.self, forKey: .version)
        manifest = try values.decode(ExtensionManifest.self, forKey: .manifest)
        owner = try values.decode(MarketplaceOwner.self, forKey: .owner)
        installCount = try values.decodeIfPresent(Int.self, forKey: .installCount) ?? 0
        reportCount = try values.decodeIfPresent(Int.self, forKey: .reportCount)
        isOwner = try values.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        canModerate = try values.decodeIfPresent(Bool.self, forKey: .canModerate) ?? false
        isHidden = try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        createdAt = try values.decode(String.self, forKey: .createdAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
    }
}

struct MarketplaceExtensionDraft: Encodable, Sendable {
    var repositoryURL: String
    var name: String
    var summary: String
    var description: String?
    var category: String?
    var tags: [String]
    var version: String
    var manifest: ExtensionManifest

    private enum CodingKeys: String, CodingKey {
        case name, summary, description, category, tags, version, manifest
        case repositoryURL = "repositoryUrl"
    }
}

enum ExtensionMarketplaceError: Error, LocalizedError, Equatable {
    case signInRequired
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in to Pass before using the extension marketplace."
        case .invalidResponse:
            return "The marketplace returned an invalid response."
        case .server(_, let message):
            return message
        }
    }
}

/// App-only client for the Cloudflare marketplace API. Public discovery requests can be
/// anonymous; account-scoped and mutating requests reuse the desktop credential in Keychain.
@MainActor
final class ExtensionMarketplaceService {
    typealias Authorization = (baseURL: URL, accessToken: String?)
    typealias AuthorizationProvider = @MainActor () async throws -> Authorization

    struct Page: Sendable {
        var extensions: [MarketplaceExtension]
        var nextCursor: String?
    }

    private struct PageResponse: Decodable {
        var extensions: [MarketplaceExtension]
        var nextCursor: String?
    }

    private struct ItemResponse: Decodable {
        var `extension`: MarketplaceExtension
    }

    private struct APIErrorResponse: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }

    private let session: URLSession
    private let authorization: AuthorizationProvider
    private var authorizationTask: Task<Authorization, Error>?
    private var authorizationRevision = 0

    init(accountService: RemoteAccountService, session: URLSession = .shared) {
        self.session = session
        authorization = {
            do {
                let registration = try await accountService.refreshDesktopRegistrationIfNeeded()
                return (registration.relayURL, registration.credentials.accessToken)
            } catch {
                guard let relayURL = RemotePublicConfiguration.loadRelayURL() else {
                    if error is RemoteAccountError {
                        throw ExtensionMarketplaceError.signInRequired
                    }
                    throw error
                }
                return (relayURL, nil)
            }
        }
    }

    /// Test seam and future market-only authentication seam. Production uses the Keychain-backed
    /// RemoteAccountService initializer above.
    init(session: URLSession, authorization: @escaping AuthorizationProvider) {
        self.session = session
        self.authorization = authorization
    }

    func list(query: String = "", category: String? = nil, ownedOnly: Bool = false,
              cursor: String? = nil, limit: Int = 50) async throws -> Page {
        var components = URLComponents()
        components.path = "v2/marketplace/extensions"
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty { queryItems.append(URLQueryItem(name: "q", value: trimmedQuery)) }
        if let category, !category.isEmpty { queryItems.append(URLQueryItem(name: "category", value: category)) }
        if ownedOnly { queryItems.append(URLQueryItem(name: "owner", value: "me")) }
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = queryItems
        let response: PageResponse = try await request(
            path: components.string ?? components.path,
            requiresAuthentication: ownedOnly)
        return Page(extensions: response.extensions, nextCursor: response.nextCursor)
    }

    func details(id: String) async throws -> MarketplaceExtension {
        let response: ItemResponse = try await request(
            path: "v2/marketplace/extensions/\(id)",
            requiresAuthentication: false)
        return response.extension
    }

    func publish(_ draft: MarketplaceExtensionDraft) async throws -> MarketplaceExtension {
        let response: ItemResponse = try await request(
            path: "v2/marketplace/extensions", method: "POST", body: draft,
            requiresAuthentication: true)
        return response.extension
    }

    func update(id: String, draft: MarketplaceExtensionDraft) async throws -> MarketplaceExtension {
        let response: ItemResponse = try await request(
            path: "v2/marketplace/extensions/\(id)", method: "PATCH", body: draft,
            requiresAuthentication: true)
        return response.extension
    }

    func delete(id: String) async throws {
        let _: EmptyResponse = try await request(
            path: "v2/marketplace/extensions/\(id)", method: "DELETE",
            requiresAuthentication: true)
    }

    func report(id: String, reason: String, details: String? = nil) async throws {
        struct Report: Encodable { var reason: String; var details: String? }
        let _: EmptyResponse = try await request(
            path: "v2/marketplace/extensions/\(id)/reports", method: "POST",
            body: Report(reason: reason, details: details), requiresAuthentication: true)
    }

    func recordInstall(id: String) async throws {
        let _: EmptyResponse = try await request(
            path: "v2/marketplace/extensions/\(id)/install", method: "POST",
            requiresAuthentication: true)
    }

    func setHidden(id: String, hidden: Bool) async throws -> MarketplaceExtension {
        struct Moderation: Encodable { var hidden: Bool }
        let response: ItemResponse = try await request(
            path: "v2/marketplace/extensions/\(id)/moderation", method: "PATCH",
            body: Moderation(hidden: hidden), requiresAuthentication: true)
        return response.extension
    }

    private struct EmptyResponse: Decodable {}

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        requiresAuthentication: Bool
    ) async throws -> Response {
        try await request(
            path: path, method: method, bodyData: nil,
            requiresAuthentication: requiresAuthentication)
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String, method: String, body: Body, requiresAuthentication: Bool
    ) async throws -> Response {
        try await request(
            path: path, method: method, bodyData: try JSONEncoder().encode(body),
            requiresAuthentication: requiresAuthentication)
    }

    private func request<Response: Decodable>(
        path: String, method: String, bodyData: Data?, requiresAuthentication: Bool
    ) async throws -> Response {
        let authorization = try await resolvedAuthorization()
        try Task.checkCancellation()
        if requiresAuthentication && authorization.accessToken == nil {
            throw ExtensionMarketplaceError.signInRequired
        }
        guard let url = URL(string: path, relativeTo: authorization.baseURL)?.absoluteURL else {
            throw ExtensionMarketplaceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let accessToken = authorization.accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw ExtensionMarketplaceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let decoded = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            throw ExtensionMarketplaceError.server(
                status: response.statusCode,
                message: decoded?.error.message ?? "Marketplace request failed (HTTP \(response.statusCode)).")
        }
        do {
            return try JSONDecoder().decode(Response.self,
                                            from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            throw ExtensionMarketplaceError.invalidResponse
        }
    }

    /// Desktop refresh credentials are rotated by the relay. Keep a single refresh in flight so
    /// concurrent marketplace requests cannot attempt to redeem the same credential twice.
    /// The task is intentionally unstructured: cancelling one HTTP request must not cancel a
    /// refresh that another request is also awaiting.
    private func resolvedAuthorization() async throws -> Authorization {
        if let authorizationTask {
            return try await authorizationTask.value
        }

        authorizationRevision &+= 1
        let revision = authorizationRevision
        let provider = authorization
        let task = Task { @MainActor in
            try await provider()
        }
        authorizationTask = task

        do {
            let value = try await task.value
            if authorizationRevision == revision { authorizationTask = nil }
            return value
        } catch {
            if authorizationRevision == revision { authorizationTask = nil }
            throw error
        }
    }
}
