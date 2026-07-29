import XCTest
@testable import Pass

@MainActor
final class ExtensionPassAPIServiceTests: XCTestCase {
    override func tearDown() {
        ExtensionPassAPIURLProtocol.handler = nil
        super.tearDown()
    }

    func testPUTKeepsCredentialInsideHostAndForwardsDeclaredJSONBody() async throws {
        var capturedBody: [String: Any]?
        ExtensionPassAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v2/usage/snapshots")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer desktop-token"
            )
            capturedBody = try JSONSerialization.jsonObject(
                with: try XCTUnwrap(request.bodyData)
            ) as? [String: Any]
            return (200, #"{"sharing":true,"publishedRows":1}"#)
        }
        let service = ExtensionPassAPIService(session: makeSession()) {
            (URL(string: "https://relay.example/")!, "desktop-token")
        }
        let result = try await service.request(
            ExtensionManifest.PassAPI(
                method: "PUT", path: "v2/usage/snapshots", bodyInput: "payload"
            ),
            context: [
                "input.payload": #"{"days":[{"date":"2026-07-29","provider":"codex","inputTokens":1,"outputTokens":2,"cacheReadTokens":3,"cacheWriteTokens":4}]}"#
            ]
        ) as? [String: Any]

        XCTAssertEqual(result?["sharing"] as? Bool, true)
        XCTAssertEqual((capturedBody?["days"] as? [[String: Any]])?.count, 1)
    }

    func testBlocksUnlistedRoutesBeforeAuthorizationOrNetwork() async {
        var authorizationCalls = 0
        ExtensionPassAPIURLProtocol.handler = { _ in
            XCTFail("Blocked request must not reach the network.")
            return (500, "{}")
        }
        let service = ExtensionPassAPIService(session: makeSession()) {
            authorizationCalls += 1
            return (URL(string: "https://relay.example/")!, "desktop-token")
        }

        do {
            _ = try await service.request(
                ExtensionManifest.PassAPI(
                    method: "DELETE", path: "v2/desktops/secret", bodyInput: nil
                ),
                context: [:]
            )
            XCTFail("Expected allowlist rejection.")
        } catch let error as ExtensionPassAPIError {
            XCTAssertEqual(error, .blocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(authorizationCalls, 0)
    }

    func testSurfacesServerMessage() async {
        ExtensionPassAPIURLProtocol.handler = { _ in
            (401, #"{"error":{"code":"unauthorized","message":"Sign in again."}}"#)
        }
        let service = ExtensionPassAPIService(session: makeSession()) {
            (URL(string: "https://relay.example/")!, "desktop-token")
        }

        do {
            _ = try await service.request(
                ExtensionManifest.PassAPI(
                    method: "GET", path: "v2/usage/leaderboard?days=30", bodyInput: nil
                ),
                context: [:]
            )
            XCTFail("Expected server error.")
        } catch let error as ExtensionPassAPIError {
            XCTAssertEqual(error, .server(status: 401, message: "Sign in again."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExtensionPassAPIURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ExtensionPassAPIURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
