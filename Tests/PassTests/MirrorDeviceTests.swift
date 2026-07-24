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
        XCTAssertEqual(devices.map(\.platform), [.android, .android, .android])
        XCTAssertEqual(devices.map(\.transport), [.usb, .network, .emulator])
        XCTAssertEqual(devices[0].displayName, "SM S918N")
        XCTAssertEqual(devices[1].displayName, "Pixel 7")
    }

    func testIOSScreenDeviceClassifierRejectsContinuityCamerasAndOtherVendors() {
        XCTAssertTrue(MirrorIOSDeviceDiscovery.isIOSScreenCaptureDevice(
            modelID: "iOS Device", manufacturer: "Apple Inc."
        ))
        XCTAssertTrue(MirrorIOSDeviceDiscovery.isIOSScreenCaptureDevice(
            modelID: "IOS DEVICE", manufacturer: "APPLE INC."
        ))
        XCTAssertFalse(MirrorIOSDeviceDiscovery.isIOSScreenCaptureDevice(
            modelID: "iPhone Camera", manufacturer: "Apple Inc."
        ))
        XCTAssertFalse(MirrorIOSDeviceDiscovery.isIOSScreenCaptureDevice(
            modelID: "iOS Device", manufacturer: "Third Party"
        ))
    }

    func testDeviceIdentityIsNamespacedByPlatformAndIOSIsViewOnly() {
        let android = MirrorDevice(serial: "shared-id", name: "Pixel", product: nil,
                                   transport: .usb)
        let ios = MirrorDevice(serial: "shared-id", name: "iPhone", product: "iOS Device",
                               platform: .iOS, transport: .usb)

        XCTAssertNotEqual(android.id, ios.id)
        XCTAssertEqual(android.detailText, "shared-id")
        XCTAssertEqual(ios.detailText, "Trusted USB screen")
        XCTAssertTrue(android.supportsPointerInput)
        XCTAssertFalse(ios.supportsPointerInput)
    }

    func testPickerOrderingKeepsIOSFirstAndAndroidTransportPriority() {
        let devices = [
            MirrorDevice(serial: "emulator-5554", name: "A Emulator", product: nil,
                         transport: .emulator),
            MirrorDevice(serial: "wifi:5555", name: "A Wi-Fi", product: nil,
                         transport: .network),
            MirrorDevice(serial: "usb", name: "Z USB", product: nil, transport: .usb),
            MirrorDevice(serial: "ios", name: "iPhone", product: "iOS Device",
                         platform: .iOS, transport: .usb),
        ]

        XCTAssertEqual(
            MirrorDevice.orderedForPicker(devices).map(\.serial),
            ["ios", "usb", "wifi:5555", "emulator-5554"]
        )
    }

    func testNetworkAddressDefaultsToADBPortAndValidatesExplicitPort() {
        XCTAssertEqual(MirrorNetworkAddress.normalized("192.168.0.24"), "192.168.0.24:5555")
        XCTAssertEqual(MirrorNetworkAddress.normalized("pixel.local:37123"), "pixel.local:37123")
        XCTAssertEqual(MirrorNetworkAddress.normalized("[fe80::1]:5555"), "[fe80::1]:5555")
        XCTAssertNil(MirrorNetworkAddress.normalized("host:0"))
        XCTAssertNil(MirrorNetworkAddress.normalized("host:70000"))
        XCTAssertNil(MirrorNetworkAddress.normalized("hello world"))
    }

    func testADBDisplaySizePrefersOverrideAndMapsNormalizedInput() {
        let output = """
        Physical size: 1080x2340
        Override size: 720x1560
        """
        let size = MirrorADBDisplaySizeParser.parse(output)
        XCTAssertEqual(size, CGSize(width: 720, height: 1560))

        let portrait = MirrorInputCoordinates.point(
            normalized: CGPoint(x: 0.5, y: 0.25),
            displaySize: size!,
            videoIsLandscape: false
        )
        XCTAssertEqual(portrait, CGPoint(x: 360, y: 390))

        let landscape = MirrorInputCoordinates.point(
            normalized: CGPoint(x: 0.5, y: 0.25),
            displaySize: size!,
            videoIsLandscape: true
        )
        XCTAssertEqual(landscape, CGPoint(x: 780, y: 180))
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
