import XCTest
@testable import Pass

final class PassConfigStoreTests: XCTestCase {
    func testLoadsStringAndObjectURLs() throws {
        let file = try write(#"""
        {
          "urls": [
            "3000",
            { "label": "Admin", "url": "admin.example.com" }
          ]
        }
        """#)

        let urls = PassConfigStore.urls(fileURL: file)

        XCTAssertEqual(urls.map(\.label), ["localhost:3000", "Admin"])
        XCTAssertEqual(urls.map(\.url.absoluteString), [
            "http://localhost:3000",
            "https://admin.example.com",
        ])
    }

    func testDropsInvalidAndDuplicateURLs() throws {
        let file = try write(#"""
        {
          "urls": [
            "javascript:alert(1)",
            "https://example.com",
            { "label": "Duplicate", "url": "https://example.com" }
          ]
        }
        """#)

        let urls = PassConfigStore.urls(fileURL: file)

        XCTAssertEqual(urls.map(\.label), ["example.com"])
        XCTAssertEqual(urls.map(\.url.absoluteString), ["https://example.com"])
    }

    func testAddsURLAndPreservesOtherSettings() throws {
        let file = try write(#"""
        {
          "theme": "dark",
          "urls": ["3000"]
        }
        """#)

        let added = try PassConfigStore.addURL(
            fileURL: file,
            rawURL: "admin.example.com",
            label: "Admin"
        )

        XCTAssertEqual(added.label, "Admin")
        XCTAssertEqual(added.url.absoluteString, "https://admin.example.com")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(object?["theme"] as? String, "dark")
        XCTAssertEqual(PassConfigStore.urls(fileURL: file).map(\.label), ["localhost:3000", "Admin"])
    }

    func testRejectsDuplicateURLWhenAdding() throws {
        let file = try write(#"""
        {
          "urls": ["https://example.com"]
        }
        """#)

        XCTAssertThrowsError(try PassConfigStore.addURL(fileURL: file, rawURL: "example.com")) { error in
            XCTAssertEqual(error as? PassConfigStore.StoreError, .duplicateURL("https://example.com"))
        }
    }

    private func write(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pass-config-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }
}
