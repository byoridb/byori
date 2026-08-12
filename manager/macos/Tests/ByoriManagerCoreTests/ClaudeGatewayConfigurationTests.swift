import XCTest
@testable import ByoriManagerCore

final class ClaudeGatewayConfigurationTests: XCTestCase {
    func testDisabledConfigurationDoesNotOverrideClaudeEnvironment() throws {
        XCTAssertEqual(
            try ClaudeGatewayConfiguration.disabled.launchEnvironment(credential: "secret"),
            [:]
        )
    }

    func testUpstageTemplateMatchesOfficialClaudeSolarEnvironment() throws {
        var configuration = ClaudeGatewayConfiguration.upstageTemplate
        configuration.isEnabled = true

        let environment = try configuration.launchEnvironment(credential: "upstage-secret")

        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://api.upstage.ai")
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "upstage-secret")
        XCTAssertEqual(environment["ANTHROPIC_MODEL"], "solar-pro4")
        XCTAssertEqual(environment["ANTHROPIC_SMALL_FAST_MODEL"], "solar-pro4")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_OPUS_MODEL"], "solar-pro4")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_SONNET_MODEL"], "solar-pro4")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "solar-pro4")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_FABLE_MODEL"], "solar-pro4")
        XCTAssertEqual(environment["API_TIMEOUT_MS"], "600000")
        XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
        XCTAssertEqual(environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "262144")
        XCTAssertEqual(environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"], "131072")
        XCTAssertEqual(environment["CLAUDE_STREAM_IDLE_TIMEOUT_MS"], "600000")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
    }

    func testCustomGatewaySupportsAPIKeyOrNoCredential() throws {
        var configuration = ClaudeGatewayConfiguration(
            isEnabled: true,
            baseURL: "http://localhost:4000",
            authentication: .anthropicAPIKey,
            model: "gateway-sonnet",
            fastModel: "gateway-haiku"
        )

        var environment = try configuration.launchEnvironment(credential: "api-secret")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "api-secret")
        XCTAssertEqual(environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "gateway-haiku")

        configuration.authentication = .none
        environment = try configuration.launchEnvironment(credential: nil)
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_AUTH_TOKEN"])
    }

    func testCredentialIsRequiredOnlyForCredentialAuthentication() {
        let configuration = ClaudeGatewayConfiguration(
            isEnabled: true,
            baseURL: "https://gateway.example.com",
            authentication: .authorizationToken,
            model: "gateway-model"
        )

        XCTAssertThrowsError(try configuration.launchEnvironment(credential: nil)) { error in
            XCTAssertEqual(error as? ClaudeGatewayConfigurationError, .missingCredential)
        }
    }
}
