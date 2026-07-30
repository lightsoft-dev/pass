import Foundation

enum ExtensionPassAPIError: Error, LocalizedError, Equatable {
    case signInRequired
    case blocked
    case missingBody
    case invalidBody
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in to Pass before sharing or viewing usage rankings."
        case .blocked:
            return "The extension requested a Pass API route that is not allowed."
        case .missingBody:
            return "The extension did not provide its declared JSON body."
        case .invalidBody:
            return "The extension provided an invalid or oversized JSON body."
        case .invalidResponse:
            return "The Pass API returned an invalid response."
        case .server(_, let message):
            return message
        }
    }
}

/// Narrow authenticated network bridge for reviewed extension actions. The extension receives
/// only decoded JSON; the desktop access credential remains in Keychain and inside this service.
@MainActor
final class ExtensionPassAPIService {
    typealias Authorization = (baseURL: URL, accessToken: String)
    typealias AuthorizationProvider = @MainActor () async throws -> Authorization

    private static let maxBodyBytes = 128 * 1_024
    private static let maxResponseBytes = 512 * 1_024

    private let session: URLSession
    private let authorization: AuthorizationProvider

    init(accountService: RemoteAccountService, session: URLSession = .shared) {
        self.session = session
        authorization = {
            do {
                let registration = try await accountService.refreshDesktopRegistrationIfNeeded()
                return (registration.relayURL, registration.credentials.accessToken)
            } catch {
                if error is RemoteAccountError {
                    throw ExtensionPassAPIError.signInRequired
                }
                throw error
            }
        }
    }

    /// Test seam. Production always uses the Keychain-backed account-service initializer.
    init(session: URLSession, authorization: @escaping AuthorizationProvider) {
        self.session = session
        self.authorization = authorization
    }

    func request(_ api: ExtensionManifest.PassAPI,
                 context: [String: String]) async throws -> Any {
        guard ExtensionCatalog.isAllowedPassAPI(method: api.method, path: api.path) else {
            throw ExtensionPassAPIError.blocked
        }
        let credential = try await authorization()
        guard let relative = URLComponents(string: api.path) else {
            throw ExtensionPassAPIError.blocked
        }
        var components = URLComponents(
            url: credential.baseURL.appending(
                path: relative.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = relative.queryItems
        guard let url = components?.url else { throw ExtensionPassAPIError.blocked }

        var request = URLRequest(url: url)
        request.httpMethod = api.method
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if api.method == "PUT" {
            guard let inputKey = api.bodyInput,
                  let rawBody = context["input." + inputKey] else {
                throw ExtensionPassAPIError.missingBody
            }
            let data = Data(rawBody.utf8)
            guard data.count <= Self.maxBodyBytes,
                  let body = try? JSONSerialization.jsonObject(with: data),
                  body is [String: Any] else {
                throw ExtensionPassAPIError.invalidBody
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }

        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maxResponseBytes,
              let http = response as? HTTPURLResponse else {
            throw ExtensionPassAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ExtensionPassAPIError.server(
                status: http.statusCode,
                message: Self.serverMessage(data) ?? "Pass API request failed."
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any] else {
            throw ExtensionPassAPIError.invalidResponse
        }
        return object
    }

    private static func serverMessage(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else { return nil }
        return message
    }
}
