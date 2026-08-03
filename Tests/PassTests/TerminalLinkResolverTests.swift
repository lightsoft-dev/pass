import XCTest
@testable import Pass

final class TerminalLinkResolverTests: XCTestCase {
    func testStopsBeforeKoreanParticleWithoutWhitespace() throws {
        let url = "https://print-so.lightsoft.dev"
        let text = url + "에서"
        let match = try XCTUnwrap(resolve(text, column: url.count - 1))

        XCTAssertEqual(match.url.absoluteString, url)
        XCTAssertEqual(match.ranges, [
            .init(row: 0, startColumn: 0, endColumn: url.count),
        ])
        XCTAssertNil(resolve(text, column: url.count))
    }

    func testDoesNotTreatTheWholeRowAsTheOnlyLinkHitArea() {
        let text = "prefix https://example.com suffix"

        XCTAssertNil(resolve(text, column: 0))
        XCTAssertNotNil(resolve(text, column: 10))
        XCTAssertNil(resolve(text, column: text.count - 1))
    }

    func testTrimsSurroundingProsePunctuation() throws {
        let text = "(https://example.com/path)."
        let match = try XCTUnwrap(resolve(text, column: 12))

        XCTAssertEqual(match.url.absoluteString, "https://example.com/path")
        XCTAssertNil(resolve(text, column: text.count - 1))
        XCTAssertNil(resolve(text, column: text.count - 2))
    }

    func testPreservesBalancedParenthesesInsideURL() throws {
        let url = "https://example.com/a_(b)"
        let match = try XCTUnwrap(resolve(url, column: url.count - 1))

        XCTAssertEqual(match.url.absoluteString, url)
    }

    func testSelectsOnlyThePointedURLWhenThereAreTwoOnOneRow() throws {
        let first = "https://one.example"
        let second = "https://two.example/path"
        let text = "\(first) and \(second)"
        let secondStart = first.count + " and ".count
        let match = try XCTUnwrap(resolve(text, column: secondStart + 10))

        XCTAssertEqual(match.url.absoluteString, second)
        XCTAssertEqual(match.ranges, [
            .init(row: 0, startColumn: secondStart, endColumn: text.count),
        ])
    }

    func testResolvesAcrossAConfirmedSoftWrap() throws {
        let first = row("see https://example", index: 4)
        let second = row(".com/a-path", index: 5, joinsPrevious: true)
        let match = try XCTUnwrap(TerminalLinkResolver.match(
            rows: [first, second],
            at: .init(row: 5, column: 5)
        ))

        XCTAssertEqual(match.url.absoluteString, "https://example.com/a-path")
        XCTAssertEqual(match.ranges, [
            .init(row: 4, startColumn: 4, endColumn: first.cells.count),
            .init(row: 5, startColumn: 0, endColumn: second.cells.count),
        ])
    }

    func testDoesNotJoinRowsAcrossAHardNewline() {
        let first = row("see https://example", index: 4)
        let second = row(".com/a-path", index: 5, joinsPrevious: false)

        XCTAssertNil(TerminalLinkResolver.match(
            rows: [first, second],
            at: .init(row: 5, column: 5)
        ))
    }

    private func resolve(_ text: String, column: Int) -> TerminalLinkResolver.Match? {
        TerminalLinkResolver.match(
            rows: [row(text, index: 0)],
            at: .init(row: 0, column: column)
        )
    }

    private func row(
        _ text: String,
        index: Int,
        joinsPrevious: Bool = false
    ) -> TerminalLinkResolver.Row {
        TerminalLinkResolver.Row(
            index: index,
            cells: text.map(Optional.some),
            joinsPrevious: joinsPrevious
        )
    }
}
