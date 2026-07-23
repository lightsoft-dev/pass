import Foundation
import XCTest
@testable import Pass

@MainActor
final class ExtensionMarketplaceTests: XCTestCase {
    override func tearDown() {
        MarketplaceURLProtocol.handler = nil
        super.tearDown()
    }

    func testListUsesDesktopBearerAndDecodesMarketplaceContract() async throws {
        let session = makeSession()
        MarketplaceURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer desktop-token")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url),
                                                         resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/v2/marketplace/extensions")
            XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "q", value: "timer")) == true)
            XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "owner", value: "me")) == true)
            return (200, Self.pageJSON)
        }
        let service = ExtensionMarketplaceService(session: session) {
            (URL(string: "https://relay.example/")!, "desktop-token")
        }

        let page = try await service.list(query: "timer", ownedOnly: true)

        XCTAssertEqual(page.extensions.map(\.name), ["Focus Timer"])
        XCTAssertEqual(page.extensions.first?.manifest.permissions, ["notify"])
        XCTAssertEqual(page.extensions.first?.owner.displayName, "Mina")
        XCTAssertEqual(page.extensions.first?.reportCount, 2)
        XCTAssertEqual(page.extensions.first?.canModerate, true)
        XCTAssertEqual(page.nextCursor, "next-page")
    }

    func testPublishEncodesManifestAndSurfacesServerMessage() async throws {
        let session = makeSession()
        var capturedBody: [String: Any]?
        MarketplaceURLProtocol.handler = { request in
            if let data = request.bodyData {
                capturedBody = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (409, #"{"error":{"code":"conflict","message":"Repository already listed."}}"#)
        }
        let service = ExtensionMarketplaceService(session: session) {
            (URL(string: "https://relay.example/")!, "desktop-token")
        }
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(#"""
        {
          "apiVersion":1,"id":"focus-timer","name":"Focus Timer","version":"1.0.0",
          "permissions":["notify"]
        }
        """#.utf8))
        let draft = MarketplaceExtensionDraft(
            repositoryURL: "https://github.com/mina/focus-timer.git", name: "Focus Timer",
            summary: "A small timer", description: nil, category: "Productivity",
            tags: ["focus"], version: "1.0.0", manifest: manifest)

        do {
            _ = try await service.publish(draft)
            XCTFail("expected conflict")
        } catch let error as ExtensionMarketplaceError {
            XCTAssertEqual(error, .server(status: 409, message: "Repository already listed."))
        }
        XCTAssertEqual(capturedBody?["repositoryUrl"] as? String,
                       "https://github.com/mina/focus-timer.git")
        XCTAssertEqual((capturedBody?["manifest"] as? [String: Any])?["id"] as? String, "focus-timer")
    }

    func testConcurrentRequestsShareOneAuthorizationRefresh() async throws {
        let session = makeSession()
        MarketplaceURLProtocol.handler = { _ in (200, Self.pageJSON) }
        var authorizationCalls = 0
        let service = ExtensionMarketplaceService(session: session) {
            authorizationCalls += 1
            try await Task.sleep(for: .milliseconds(50))
            return (URL(string: "https://relay.example/")!, "desktop-token")
        }

        let first = Task { @MainActor in try await service.list(query: "first") }
        let second = Task { @MainActor in try await service.list(query: "second") }
        _ = try await (first.value, second.value)

        XCTAssertEqual(authorizationCalls, 1)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MarketplaceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let pageJSON = #"""
    {
      "extensions":[{
        "id":"mkt_123","repositoryUrl":"https://github.com/mina/focus-timer.git",
        "name":"Focus Timer","summary":"A small timer","category":"Productivity",
        "tags":["focus","timer"],"version":"1.0.0",
        "manifest":{"apiVersion":1,"id":"focus-timer","name":"Focus Timer","version":"1.0.0","permissions":["notify"]},
        "owner":{"id":"acct_123","displayName":"Mina"},"installCount":7,"reportCount":2,
        "isOwner":true,"canModerate":true,
        "createdAt":"2026-07-22T00:00:00.000Z","updatedAt":"2026-07-22T00:00:00.000Z"
      }],"nextCursor":"next-page"
    }
    """#
}

private final class MarketplaceURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
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
