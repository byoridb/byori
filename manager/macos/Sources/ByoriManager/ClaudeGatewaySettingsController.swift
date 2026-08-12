import ByoriManagerCore
import Foundation
import Security

protocol ClaudeGatewayCredentialStoring {
    func readCredential() throws -> String?
    func writeCredential(_ credential: String) throws
    func deleteCredential() throws
}

enum ClaudeGatewayCredentialStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "Keychain could not update the Claude gateway credential (status \(status))."
        case .invalidData:
            return "The Claude gateway credential in Keychain is not valid UTF-8."
        }
    }
}

struct KeychainClaudeGatewayCredentialStore: ClaudeGatewayCredentialStoring {
    private let service: String
    private let account = "claude-gateway-credential"

    init(service: String = Bundle.main.bundleIdentifier ?? "app.byorimanager") {
        self.service = service
    }

    func readCredential() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ClaudeGatewayCredentialStoreError.keychain(status)
        }
        guard let data = result as? Data, let credential = String(data: data, encoding: .utf8) else {
            throw ClaudeGatewayCredentialStoreError.invalidData
        }
        return credential
    }

    func writeCredential(_ credential: String) throws {
        let data = Data(credential.utf8)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ClaudeGatewayCredentialStoreError.keychain(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ClaudeGatewayCredentialStoreError.keychain(addStatus)
        }
    }

    func deleteCredential() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeGatewayCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Owns a saved, active configuration and a separately editable draft. This
/// lets Settings offer Save/Restore semantics without partially applying a URL
/// or model name while the user is still typing.
@MainActor
final class ClaudeGatewaySettingsController: ObservableObject {
    @Published var draft: ClaudeGatewayConfiguration
    @Published var credentialInput = ""
    @Published private(set) var activeConfiguration: ClaudeGatewayConfiguration
    @Published private(set) var hasStoredCredential: Bool

    private let defaults: UserDefaults
    private let credentialStore: any ClaudeGatewayCredentialStoring
    private let configurationKey: String

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any ClaudeGatewayCredentialStoring = KeychainClaudeGatewayCredentialStore(),
        configurationKey: String = "claudeGatewayConfiguration.v1"
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.configurationKey = configurationKey

        let configuration: ClaudeGatewayConfiguration
        if let data = defaults.data(forKey: configurationKey),
           let decoded = try? JSONDecoder().decode(ClaudeGatewayConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .disabled
        }
        activeConfiguration = configuration
        draft = configuration
        hasStoredCredential = (try? credentialStore.readCredential()) != nil
    }

    func selectPreset(_ preset: ClaudeGatewayPreset) {
        let wasEnabled = draft.isEnabled
        switch preset {
        case .custom:
            draft.preset = .custom
            draft.routeAllModelFamilies = false
        case .upstageSolar:
            draft = .upstageTemplate
            draft.isEnabled = wasEnabled
        }
    }

    func save() throws {
        var configuration = draft
        if configuration.preset == .upstageSolar {
            configuration.baseURL = ClaudeGatewayConfiguration.upstageTemplate.baseURL
            configuration.authentication = .authorizationToken
            configuration.routeAllModelFamilies = true
        }
        let replacement = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedCredential = try credentialStore.readCredential()
        let credential = replacement.isEmpty ? storedCredential : replacement
        _ = try configuration.launchEnvironment(credential: credential)

        if configuration.authentication.requiresCredential, !replacement.isEmpty {
            try credentialStore.writeCredential(replacement)
        }
        try persist(configuration)
        activeConfiguration = configuration
        draft = configuration
        credentialInput = ""
        hasStoredCredential = (try credentialStore.readCredential()) != nil
    }

    /// Stops all Byori injection for future launches without modifying Claude's
    /// own files or deleting a reusable gateway profile.
    func restoreClaudeDefault() throws {
        var restored = activeConfiguration
        restored.isEnabled = false
        try persist(restored)
        activeConfiguration = restored
        draft = restored
        credentialInput = ""
    }

    func deleteStoredCredential() throws {
        try credentialStore.deleteCredential()
        hasStoredCredential = false
        credentialInput = ""
        if activeConfiguration.authentication.requiresCredential,
           activeConfiguration.isEnabled {
            try restoreClaudeDefault()
        }
    }

    func discardDraft() {
        draft = activeConfiguration
        credentialInput = ""
    }

    func launchEnvironment() throws -> [String: String] {
        let credential = try credentialStore.readCredential()
        return try activeConfiguration.launchEnvironment(credential: credential)
    }

    private func persist(_ configuration: ClaudeGatewayConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: configurationKey)
    }
}
