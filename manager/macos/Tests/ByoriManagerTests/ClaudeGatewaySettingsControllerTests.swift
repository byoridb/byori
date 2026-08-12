import XCTest
@testable import ByoriManager
@testable import ByoriManagerCore

@MainActor
final class ClaudeGatewaySettingsControllerTests: XCTestCase {
    func testSavePersistsOnlyNonSecretConfigurationAndBuildsLaunchEnvironment() throws {
        let suite = "ClaudeGatewaySettingsControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestCredentialStore()
        let controller = ClaudeGatewaySettingsController(
            defaults: defaults,
            credentialStore: credentials
        )
        controller.draft = .upstageTemplate
        controller.draft.isEnabled = true
        controller.draft.baseURL = "https://gateway.example.com"
        controller.credentialInput = "upstage-secret"

        try controller.save()

        XCTAssertTrue(controller.activeConfiguration.isEnabled)
        XCTAssertEqual(try controller.launchEnvironment()["ANTHROPIC_AUTH_TOKEN"], "upstage-secret")
        let persisted = try XCTUnwrap(defaults.data(forKey: "claudeGatewayConfiguration.v1"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("upstage-secret"))
    }

    func testRestoreDisablesInjectionWithoutDeletingReusableCredential() throws {
        let suite = "ClaudeGatewaySettingsControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestCredentialStore()
        let controller = ClaudeGatewaySettingsController(
            defaults: defaults,
            credentialStore: credentials
        )
        controller.draft = ClaudeGatewayConfiguration(
            isEnabled: true,
            baseURL: "https://gateway.example.com",
            authentication: .authorizationToken,
            model: "gateway-model"
        )
        controller.credentialInput = "secret"
        try controller.save()

        try controller.restoreClaudeDefault()

        XCTAssertEqual(try controller.launchEnvironment(), [:])
        XCTAssertEqual(try credentials.readCredential(), "secret")
        XCTAssertTrue(controller.hasStoredCredential)
    }

    func testDeletingActiveCredentialAlsoRestoresClaudeDefault() throws {
        let suite = "ClaudeGatewaySettingsControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestCredentialStore()
        let controller = ClaudeGatewaySettingsController(
            defaults: defaults,
            credentialStore: credentials
        )
        controller.draft = ClaudeGatewayConfiguration(
            isEnabled: true,
            baseURL: "https://gateway.example.com",
            authentication: .authorizationToken,
            model: "gateway-model"
        )
        controller.credentialInput = "secret"
        try controller.save()

        try controller.deleteStoredCredential()

        XCTAssertFalse(controller.activeConfiguration.isEnabled)
        XCTAssertNil(try credentials.readCredential())
    }
}

private final class TestCredentialStore: ClaudeGatewayCredentialStoring {
    private var credential: String?

    func readCredential() throws -> String? { credential }
    func writeCredential(_ credential: String) throws { self.credential = credential }
    func deleteCredential() throws { credential = nil }
}
