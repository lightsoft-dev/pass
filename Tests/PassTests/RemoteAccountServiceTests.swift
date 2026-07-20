import XCTest
@testable import Pass

final class RemoteAccountServiceTests: XCTestCase {
    func testLoadsPublicConfigurationFromBuildValues() throws {
        let configuration = try XCTUnwrap(RemotePublicConfiguration.load(
            environment: [:],
            bundleValues: [
                RemotePublicConfigurationKey.relayURL: "https://relay.example.com/",
                RemotePublicConfigurationKey.oidcIssuer: "https://identity.example.com/",
                RemotePublicConfigurationKey.oidcClientID: "native-client",
                RemotePublicConfigurationKey.oidcAudience: "pass-api",
            ]
        ))

        XCTAssertEqual(configuration.relayURL.absoluteString, "https://relay.example.com/")
        XCTAssertEqual(configuration.issuer.absoluteString, "https://identity.example.com/")
        XCTAssertEqual(configuration.clientID, "native-client")
        XCTAssertEqual(configuration.audience, "pass-api")
        XCTAssertEqual(configuration.redirectURL.absoluteString, "pass://oauth")
    }

    func testRejectsInsecurePublicConfiguration() {
        let configuration = RemotePublicConfiguration.load(
            environment: [
                "PASS_PUBLIC_RELAY_URL": "http://relay.example.com",
                "PASS_OIDC_ISSUER": "https://identity.example.com",
                "PASS_OIDC_CLIENT_ID": "native-client",
                "PASS_OIDC_AUDIENCE": "pass-api",
            ],
            bundleValues: [:]
        )

        XCTAssertNil(configuration)
    }

    func testSecureDesktopRegistrationDefinesGatewayIdentity() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = RemoteDesktopRegistration(
            id: "desk_registered",
            name: "Studio Mac",
            relayURL: try XCTUnwrap(URL(string: "https://relay.example.com")),
            credentials: RemoteCredentialPair(
                accessToken: "pass_at_credential",
                accessExpiresAt: "2026-07-18T12:15:00.000Z",
                refreshToken: "pass_rt_credential",
                refreshExpiresAt: "2026-08-17T12:00:00.000Z"
            )
        )

        let configuration = RemoteGatewayConfiguration.load(
            environment: [:],
            defaults: defaults,
            secureRegistration: registration,
            publicConfigurationAvailable: true
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.desktopID, "desk_registered")
        XCTAssertEqual(configuration.authorizationToken, "pass_at_credential")
        XCTAssertEqual(try configuration.validatedRelayURL().absoluteString, "wss://relay.example.com/connect")
    }

    func testPublicBuildStaysDisabledUntilDesktopIsRegistered() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: RemoteGatewayPreferenceKey.enabled)
        defaults.set("wss://legacy.example.com/connect", forKey: RemoteGatewayPreferenceKey.relayURL)
        defaults.set("legacy-token", forKey: RemoteGatewayPreferenceKey.authorizationToken)

        let configuration = RemoteGatewayConfiguration.load(
            environment: [:],
            defaults: defaults,
            secureRegistration: nil,
            publicConfigurationAvailable: true
        )

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertNil(configuration.authorizationToken)
    }

    func testEnvironmentDevelopmentOverrideWinsOverSecureRegistration() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = RemoteDesktopRegistration(
            id: "desk_registered",
            name: "Studio Mac",
            relayURL: try XCTUnwrap(URL(string: "https://relay.example.com")),
            credentials: RemoteCredentialPair(
                accessToken: "production-token",
                accessExpiresAt: "2026-07-18T12:15:00.000Z",
                refreshToken: "production-refresh",
                refreshExpiresAt: "2026-08-17T12:00:00.000Z"
            )
        )

        let configuration = RemoteGatewayConfiguration.load(
            environment: [
                "PASS_REMOTE_ENABLED": "1",
                "PASS_REMOTE_URL": "ws://127.0.0.1:8787",
                "PASS_REMOTE_DESKTOP_ID": "desk_test",
                "PASS_REMOTE_TOKEN": "test-token",
            ],
            defaults: defaults,
            secureRegistration: registration,
            publicConfigurationAvailable: true
        )

        XCTAssertEqual(configuration.desktopID, "desk_test")
        XCTAssertEqual(configuration.authorizationToken, "test-token")
        XCTAssertEqual(try configuration.validatedRelayURL().absoluteString, "ws://127.0.0.1:8787/connect")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "RemoteAccountServiceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
