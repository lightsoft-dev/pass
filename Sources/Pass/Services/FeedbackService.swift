import Foundation

enum FeedbackKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case request
    case feedback
    case bug

    var id: String { rawValue }

    var label: String {
        switch self {
        case .request: "Request"
        case .feedback: "Feedback"
        case .bug: "Bug"
        }
    }

    var symbol: String {
        switch self {
        case .request: "sparkles"
        case .feedback: "quote.bubble"
        case .bug: "ladybug"
        }
    }
}

struct FeedbackSubmission: Codable, Equatable, Sendable {
    let type: FeedbackKind
    let title: String
    let message: String
    let email: String?
    let appVersion: String
    let osVersion: String
}

enum FeedbackServiceError: Error, LocalizedError {
    case unavailable
    case invalidResponse
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Feedback is not configured in this build."
        case .invalidResponse:
            "The feedback service returned an invalid response."
        case .rejected(let message):
            message
        }
    }
}

enum FeedbackService {
    static func submit(
        type: FeedbackKind,
        title: String,
        message: String,
        email: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleValues: [String: Any] = Bundle.main.infoDictionary ?? [:],
        session: URLSession = .shared
    ) async throws {
        guard let endpoint = endpoint(environment: environment, bundleValues: bundleValues) else {
            throw FeedbackServiceError.unavailable
        }

        let version = bundleValues["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = bundleValues["CFBundleVersion"] as? String
        let submission = FeedbackSubmission(
            type: type,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            appVersion: build.map { "\(version) (\($0))" } ?? version,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(submission)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(FeedbackErrorResponse.self, from: data)
            throw FeedbackServiceError.rejected(
                payload?.error.message ?? "Could not send feedback. Please try again."
            )
        }
    }

    static func endpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleValues: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> URL? {
        let raw = environment["PASS_FEEDBACK_URL"]
            ?? bundleValues["PassFeedbackURL"] as? String
            ?? environment["PASS_PUBLIC_RELAY_URL"]
            ?? bundleValues[RemotePublicConfigurationKey.relayURL] as? String
        guard
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            let baseURL = URL(string: trimmed),
            baseURL.scheme?.lowercased() == "https",
            baseURL.host != nil
        else { return nil }
        return baseURL.appending(path: "v2/feedback")
    }
}

private struct FeedbackErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
