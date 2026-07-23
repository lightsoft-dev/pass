import XCTest
@testable import Pass

final class MirrorDeviceTests: XCTestCase {
    func testADBDevicesParserKeepsOnlyAuthorizedDevicesAndClassifiesTransport() {
        let output = """
        List of devices attached
        R5CT1234 device product:dm3q model:SM_S918N device:dm3q transport_id:2
        192.168.0.24:5555 device product:panther model:Pixel_7 device:panther transport_id:3
        emulator-5554 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:4
        pending unauthorized usb:1-2 transport_id:5

        """

        let devices = MirrorADBDevicesParser.parse(output)

        XCTAssertEqual(devices.map(\.serial), ["R5CT1234", "192.168.0.24:5555", "emulator-5554"])
        XCTAssertEqual(devices.map(\.transport), [.usb, .network, .emulator])
        XCTAssertEqual(devices[0].displayName, "SM S918N")
        XCTAssertEqual(devices[1].displayName, "Pixel 7")
    }

    func testNetworkAddressDefaultsToADBPortAndValidatesExplicitPort() {
        XCTAssertEqual(MirrorNetworkAddress.normalized("192.168.0.24"), "192.168.0.24:5555")
        XCTAssertEqual(MirrorNetworkAddress.normalized("pixel.local:37123"), "pixel.local:37123")
        XCTAssertEqual(MirrorNetworkAddress.normalized("[fe80::1]:5555"), "[fe80::1]:5555")
        XCTAssertNil(MirrorNetworkAddress.normalized("host:0"))
        XCTAssertNil(MirrorNetworkAddress.normalized("host:70000"))
        XCTAssertNil(MirrorNetworkAddress.normalized("hello world"))
    }

    func testJPEGStreamParserReturnsNewestCompleteFrameAcrossChunks() {
        let parser = JPEGFrameParser()
        XCTAssertNil(parser.append(Data([0xff])))
        XCTAssertEqual(parser.append(Data([0xd8, 0x01, 0xff, 0xd9, 0xff, 0xd8, 0x02])),
                       Data([0xff, 0xd8, 0x01, 0xff, 0xd9]))
        XCTAssertEqual(parser.append(Data([0x03, 0xff, 0xd9])),
                       Data([0xff, 0xd8, 0x02, 0x03, 0xff, 0xd9]))
    }
}
