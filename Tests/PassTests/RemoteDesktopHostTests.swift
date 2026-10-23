#if !SWIFT_PACKAGE && os(macOS)
import CoreGraphics
import Foundation
import XCTest
@testable import Pass

final class RemoteDesktopHostTests: XCTestCase {
    @MainActor
    func testApprovalRequiresLocalEnablementAndExpiresAfterRenewal() async throws {
        let host = RemoteDesktopHost()
        let controllerID = "relay-verified-device"

        XCTAssertThrowsError(try host.approve(
            controllerID: controllerID,
            expiresAt: Date().addingTimeInterval(10)
        ))

        await host.setEnabled(true)
        XCTAssertThrowsError(try host.approve(
            controllerID: controllerID,
            expiresAt: Date().addingTimeInterval(-1)
        ))

        try host.approve(controllerID: controllerID, expiresAt: Date().addingTimeInterval(1))
        try host.approve(controllerID: controllerID, expiresAt: Date().addingTimeInterval(3))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(host.approvedControllerIDs.contains(controllerID))

        try await Task.sleep(nanoseconds: 1_700_000_000)
        XCTAssertFalse(host.approvedControllerIDs.contains(controllerID))
        await host.setEnabled(false)
    }

    func testBrowserInputContractDecodesAndRejectsUnsafeValues() throws {
        func decode(_ json: String) throws -> RemoteDesktopInputEvent {
            try JSONDecoder().decode(RemoteDesktopInputEvent.self, from: Data(json.utf8))
        }

        XCTAssertEqual(
            try decode(#"{"type":"pointer","action":"down","x":0.5,"y":1,"button":0,"buttons":1}"#),
            .mouseButton(.left, down: true, x: 0.5, y: 1)
        )
        XCTAssertEqual(
            try decode(#"{"type":"wheel","x":0.25,"y":0.75,"deltaX":3,"deltaY":-2}"#),
            .scroll(x: 0.25, y: 0.75, deltaX: 3, deltaY: -2)
        )
        XCTAssertEqual(
            try decode(#"{"type":"key","action":"down","code":"KeyA","key":"a","repeat":false,"modifiers":{"shift":true}}"#),
            .key(code: 0, down: true, isRepeat: false, modifiers: CGEventFlags.maskShift.rawValue)
        )
        XCTAssertEqual(try decode(#"{"type":"text","text":"한글"}"#), .text("한글"))

        XCTAssertThrowsError(try decode(#"{"type":"pointer","action":"move","x":1.01,"y":0}"#))
        XCTAssertThrowsError(try decode(#"{"type":"key","action":"down","code":"Power"}"#))
        XCTAssertThrowsError(try decode(#"{"type":"text","text":"\u0000"}"#))
        let oversized = String(repeating: "가", count: 257)
        let oversizedData = try JSONEncoder().encode(["type": "text", "text": oversized])
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteDesktopInputEvent.self, from: oversizedData))
    }
}
#endif
