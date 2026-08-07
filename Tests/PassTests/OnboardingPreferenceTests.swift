import AppKit
import XCTest
@testable import Pass

final class OnboardingPreferenceTests: XCTestCase {
    func testAppPresenceDefaultsToMenuBar() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(OnboardingPreference.appPresence(in: defaults), .menuBar)
        XCTAssertEqual(AppPresence.menuBar.activationPolicy, .accessory)
    }

    func testAppPresencePersistsDockChoice() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        OnboardingPreference.setAppPresence(.dock, in: defaults)

        XCTAssertEqual(OnboardingPreference.appPresence(in: defaults), .dock)
        XCTAssertEqual(AppPresence.dock.activationPolicy, .regular)
    }

    func testInvalidAppPresenceFallsBackToMenuBar() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown", forKey: OnboardingPreference.appPresenceKey)

        XCTAssertEqual(OnboardingPreference.appPresence(in: defaults), .menuBar)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "OnboardingPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
