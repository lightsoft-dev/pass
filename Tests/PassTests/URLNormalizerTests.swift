import XCTest
@testable import Pass

/// The BROWSER.md §7.1 table, executed. File existence is injected — no real filesystem.
final class URLNormalizerTests: XCTestCase {
    private func norm(_ raw: String, base: String? = nil,
                      exists: Bool = true) -> Result<URL, URLNormalizer.Failure> {
        URLNormalizer.normalize(raw, fileBase: base, fileExists: { _ in exists })
    }

    private func url(_ raw: String, base: String? = nil, exists: Bool = true) -> String? {
        try? norm(raw, base: base, exists: exists).get().absoluteString
    }

    func testExplicitSchemesPassThrough() {
        XCTAssertEqual(url("http://localhost:5173"), "http://localhost:5173")
        XCTAssertEqual(url("https://github.com/a/b#c"), "https://github.com/a/b#c")
        XCTAssertEqual(url("file:///tmp/x.html"), "file:///tmp/x.html")
        XCTAssertEqual(url("HTTPS://Example.com"), "HTTPS://Example.com") // case-insensitive prefix
    }

    func testBarePortsGoToLocalhost() {
        XCTAssertEqual(url("5173"), "http://localhost:5173")
        XCTAssertEqual(url(":5173"), "http://localhost:5173")
        XCTAssertEqual(url(":5173/admin"), "http://localhost:5173/admin")
        XCTAssertEqual(url("  5173  "), "http://localhost:5173") // whitespace trimmed
    }

    func testInvalidPortsRejected() {
        XCTAssertEqual(norm("0"), .failure(.invalidPort))
        XCTAssertEqual(norm(":0"), .failure(.invalidPort))
        XCTAssertEqual(norm("99999999"), .failure(.invalidPort))
    }

    func testLocalhostFamilyGetsHTTP() {
        XCTAssertEqual(url("localhost:5173"), "http://localhost:5173")
        XCTAssertEqual(url("localhost"), "http://localhost")
        XCTAssertEqual(url("127.0.0.1:3000/x"), "http://127.0.0.1:3000/x")
        XCTAssertEqual(url("0.0.0.0:8080"), "http://0.0.0.0:8080")
    }

    func testBareDomainsGetHTTPS() {
        XCTAssertEqual(url("foo.com/bar"), "https://foo.com/bar")
        XCTAssertEqual(url("github.com"), "https://github.com")
        XCTAssertEqual(url("foo.com:8080/x"), "https://foo.com:8080/x") // dotted head ≠ scheme
    }

    func testDisallowedSchemes() {
        XCTAssertEqual(norm("javascript:alert(1)"), .failure(.schemeNotAllowed("javascript")))
        XCTAssertEqual(norm("mailto:x@y.com"), .failure(.schemeNotAllowed("mailto")))
        XCTAssertEqual(norm("ftp://x.com/f"), .failure(.schemeNotAllowed("ftp")))
        XCTAssertEqual(norm("vscode://file/x"), .failure(.schemeNotAllowed("vscode")))
        XCTAssertEqual(norm("data:text/html,hi"), .failure(.schemeNotAllowed("data")))
        // about: is refused for INPUT — only pass itself opens about:blank internally.
        XCTAssertEqual(norm("about:blank"), .failure(.schemeNotAllowed("about")))
    }

    func testAbsoluteFilePaths() {
        XCTAssertEqual(url("/tmp/x.html"), "file:///tmp/x.html")
        XCTAssertEqual(norm("/tmp/missing.html", exists: false),
                       .failure(.fileNotFound("/tmp/missing.html")))
    }

    func testRelativeFilePathsResolveAgainstBase() {
        XCTAssertEqual(url("./dist/index.html", base: "/proj"), "file:///proj/dist/index.html")
        XCTAssertEqual(url("../shared/x.html", base: "/proj/app"), "file:///proj/shared/x.html")
        XCTAssertEqual(norm("./x.html"), .failure(.relativeNeedsBase)) // no base to resolve against
    }

    func testEmptyInputs() {
        XCTAssertEqual(norm(""), .failure(.empty))
        XCTAssertEqual(norm("   "), .failure(.empty))
    }
}
