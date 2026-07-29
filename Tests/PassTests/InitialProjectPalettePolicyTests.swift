import XCTest
@testable import Pass

final class InitialProjectPalettePolicyTests: XCTestCase {
    func testOffersCreateNewAfterEmptyTrackedDirectoryFinishesSyncing() {
        XCTAssertTrue(
            InitialProjectPalettePolicy.shouldOfferCreateNew(
                sessionCount: 0,
                projectCount: 0,
                projectDirectoryCount: 1,
                isSyncing: false
            )
        )
    }

    func testDoesNotOfferCreateNewBeforeDiscoveryFinishes() {
        XCTAssertFalse(
            InitialProjectPalettePolicy.shouldOfferCreateNew(
                sessionCount: 0,
                projectCount: 0,
                projectDirectoryCount: 1,
                isSyncing: true
            )
        )
    }

    func testDoesNotOfferCreateNewWithoutATrackedDirectory() {
        XCTAssertFalse(
            InitialProjectPalettePolicy.shouldOfferCreateNew(
                sessionCount: 0,
                projectCount: 0,
                projectDirectoryCount: 0,
                isSyncing: false
            )
        )
    }

    func testDoesNotReplaceExistingSessionOrProjectResults() {
        XCTAssertFalse(
            InitialProjectPalettePolicy.shouldOfferCreateNew(
                sessionCount: 1,
                projectCount: 0,
                projectDirectoryCount: 1,
                isSyncing: false
            )
        )
        XCTAssertFalse(
            InitialProjectPalettePolicy.shouldOfferCreateNew(
                sessionCount: 0,
                projectCount: 1,
                projectDirectoryCount: 1,
                isSyncing: false
            )
        )
    }

    func testUsesTheOnlyTrackedDirectoryWhenNoDefaultIsConfigured() {
        XCTAssertEqual(
            InitialProjectPalettePolicy.preferredParentDirectory(
                configured: "  ",
                projectDirectories: ["/work/projects"]
            ),
            "/work/projects"
        )
    }

    func testKeepsConfiguredParentAndAvoidsGuessingAmongSeveralDirectories() {
        XCTAssertEqual(
            InitialProjectPalettePolicy.preferredParentDirectory(
                configured: "/preferred",
                projectDirectories: ["/a", "/b"]
            ),
            "/preferred"
        )
        XCTAssertNil(
            InitialProjectPalettePolicy.preferredParentDirectory(
                configured: nil,
                projectDirectories: ["/a", "/b"]
            )
        )
    }
}
