import Foundation

public enum ClaudeGatewayPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case custom
    case upstageSolar

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .custom: return "Custom gateway"
        case .upstageSolar: return "Upstage Solar"
        }
    }
}

public enum ClaudeGatewayAuthentication: String, CaseIterable, Codable, Identifiable, Sendable {
    case authorizationToken
    case anthropicAPIKey
    case none

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .authorizationToken: return "Bearer token"
        case .anthropicAPIKey: return "API key (x-api-key)"
        case .none: return "No credential"
        }
    }

    public var requiresCredential: Bool { self != .none }
}

public enum ClaudeGatewayConfigurationError: LocalizedError, Equatable {
    case missingBaseURL
    case invalidBaseURL
    case missingModel
    case missingCredential

    public var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Enter the Anthropic-compatible gateway URL."
        case .invalidBaseURL:
            return "Use an absolute HTTP or HTTPS gateway URL without embedded credentials, query parameters, or fragments."
        case .missingModel:
            return "Enter the model name exposed by the gateway."
        case .missingCredential:
            return "Enter a gateway credential or choose No credential."
        }
    }
}

/// Non-secret Claude Code gateway settings. The credential is deliberately
/// stored separately in Keychain by the macOS app.
public struct ClaudeGatewayConfiguration: Codable, Equatable, Sendable {
    private static let baseEnvironmentKeys: Set<String> = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL",
    ]

    private static let upstageEnvironmentKeys: Set<String> = [
        "API_TIMEOUT_MS",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
        "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
        "CLAUDE_STREAM_IDLE_TIMEOUT_MS",
    ]

    public static let managedEnvironmentKeys = baseEnvironmentKeys.union(upstageEnvironmentKeys)

    public var isEnabled: Bool
    public var preset: ClaudeGatewayPreset
    public var baseURL: String
    public var authentication: ClaudeGatewayAuthentication
    public var model: String
    public var fastModel: String
    public var routeAllModelFamilies: Bool

    public init(
        isEnabled: Bool = false,
        preset: ClaudeGatewayPreset = .custom,
        baseURL: String = "",
        authentication: ClaudeGatewayAuthentication = .authorizationToken,
        model: String = "",
        fastModel: String = "",
        routeAllModelFamilies: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.preset = preset
        self.baseURL = baseURL
        self.authentication = authentication
        self.model = model
        self.fastModel = fastModel
        self.routeAllModelFamilies = routeAllModelFamilies
    }

    public static var disabled: Self { Self() }

    public static var upstageTemplate: Self {
        Self(
            isEnabled: false,
            preset: .upstageSolar,
            baseURL: "https://api.upstage.ai",
            authentication: .authorizationToken,
            model: "solar-pro4",
            fastModel: "solar-pro4",
            routeAllModelFamilies: true
        )
    }

    public var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedFastModel: String {
        fastModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var usesUnencryptedTransport: Bool {
        URLComponents(string: normalizedBaseURL)?.scheme?.lowercased() == "http"
    }

    public var environmentKeysToReplace: Set<String> {
        guard isEnabled else { return [] }
        return preset == .upstageSolar
            ? Self.managedEnvironmentKeys
            : Self.baseEnvironmentKeys
    }

    /// Environment injected only into new Claude Code sessions. An empty map
    /// means Byori leaves the user's ordinary Claude login/config untouched.
    public func launchEnvironment(credential: String?) throws -> [String: String] {
        guard isEnabled else { return [:] }

        let baseURL = normalizedBaseURL
        guard !baseURL.isEmpty else {
            throw ClaudeGatewayConfigurationError.missingBaseURL
        }
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ClaudeGatewayConfigurationError.invalidBaseURL
        }
        let model = normalizedModel
        guard !model.isEmpty else {
            throw ClaudeGatewayConfigurationError.missingModel
        }

        var environment = [
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_MODEL": model,
        ]

        if routeAllModelFamilies {
            environment["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model
            environment["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model
            environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = normalizedFastModel.isEmpty
                ? model
                : normalizedFastModel
            environment["ANTHROPIC_DEFAULT_FABLE_MODEL"] = model
        } else if !normalizedFastModel.isEmpty {
            environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = normalizedFastModel
        }

        if preset == .upstageSolar {
            let fastModel = normalizedFastModel.isEmpty ? model : normalizedFastModel
            environment["ANTHROPIC_SMALL_FAST_MODEL"] = fastModel
            environment["API_TIMEOUT_MS"] = "600000"
            environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = "262144"
            environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = "131072"
            environment["CLAUDE_STREAM_IDLE_TIMEOUT_MS"] = "600000"
        }

        switch authentication {
        case .none:
            break
        case .authorizationToken, .anthropicAPIKey:
            guard let credential, !credential.isEmpty else {
                throw ClaudeGatewayConfigurationError.missingCredential
            }
            let key = authentication == .authorizationToken
                ? "ANTHROPIC_AUTH_TOKEN"
                : "ANTHROPIC_API_KEY"
            environment[key] = credential
        }
        return environment
    }
}
