import XCTest
@testable import Pass

final class EmojiCatalogTests: XCTestCase {
    func testParsesEmojiAndKeywords() {
        XCTAssertFalse(EmojiCatalog.all.isEmpty)
        // Every entry has a non-empty emoji and at least one keyword.
        for e in EmojiCatalog.all {
            XCTAssertFalse(e.emoji.isEmpty)
            XCTAssertFalse(e.keywords.isEmpty, "no keywords for \(e.emoji)")
        }
    }

    func testSearchFindsByKeyword() {
        XCTAssertTrue(EmojiCatalog.search("rocket").contains("🚀"))
        XCTAssertTrue(EmojiCatalog.search("fire").contains("🔥"))
        XCTAssertTrue(EmojiCatalog.search("cat").contains("🐱"))
    }

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(EmojiCatalog.search("").count, EmojiCatalog.all.count)
    }

    func testPrefixMatchesRankBeforeSubstring() {
        // "bug" prefixes 🐛(bug) and appears as substring in 🦠(...bug). Prefix should come first.
        let r = EmojiCatalog.search("bug")
        if let bug = r.firstIndex(of: "🐛"), let germ = r.firstIndex(of: "🦠") {
            XCTAssertLessThan(bug, germ)
        } else {
            XCTAssertTrue(r.contains("🐛"))
        }
    }

    func testNoMatchIsEmpty() {
        XCTAssertTrue(EmojiCatalog.search("zzzznotarealkeyword").isEmpty)
    }
}
