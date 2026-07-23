// swift-tools-version: 6.0
import PackageDescription

// SwiftPM manifest for the PORTABLE subset of pass — the Linux port builds from here.
// The macOS app keeps building via project.yml/xcodegen (see BUILD.md); this package
// deliberately excludes the AppKit/SwiftUI surfaces (App, UI, share sheet, and the
// Services/Server files that touch them). docs/LINUX.md tracks what is excluded and why.
let package = Package(
    name: "Pass",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Pass", targets: ["Pass"]),
        .executable(name: "passcli", targets: ["passcli"]),
        .executable(name: "pass-smoke", targets: ["pass-smoke"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox", from: "0.20.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "Pass",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
            ],
            path: "Sources/Pass",
            exclude: [
                // Whole layers that are macOS-only today.
                "App",
                "UI",
                // SwiftUI AttributedString output — UI-layer concern despite living in Core.
                "Core/AnsiRenderer.swift",
                // Take AppModel (App layer) directly; portable once re-wired via handlers.
                "Server/CLIAPI.swift",
                "Server/ShareAPI.swift",
                // AppKit / Apple-framework services (notifications, hotkey, login item,
                // AppleScript terminal attach, NSWorkspace extension actions).
                "Services/AttachService.swift",
                "Services/ChromeProfileImportService.swift",
                "Services/ExtensionRuntime.swift",
                "Services/HotkeyService.swift",
                "Services/LoginItemService.swift",
                "Services/NotificationService.swift",
                // Guided macOS setup orchestrates AppModel and AppKit-only services.
                "Services/OnboardingService.swift",
            ]
        ),
        .executableTarget(
            name: "passcli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/PassCli"
        ),
        // XCTest-free runtime smoke (the Static Linux SDK has no XCTest). Uses @testable
        // import, so it builds in debug config only.
        .executableTarget(
            name: "pass-smoke",
            dependencies: ["Pass"],
            path: "Sources/PassSmoke"
        ),
        .testTarget(
            name: "PassTests",
            dependencies: ["Pass"],
            path: "Tests/PassTests",
            exclude: [
                // Tests the CLIAPI↔AppModel adapter, which is excluded above.
                "CLIAPITests.swift",
                // Tests AppKit UI mirror types, excluded from the portable Pass target.
                "MirrorDeviceTests.swift",
                // Tests SwiftUI/AppKit terminal views, excluded from the portable Pass target.
                "TerminalMouseInteractionPolicyTests.swift",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
