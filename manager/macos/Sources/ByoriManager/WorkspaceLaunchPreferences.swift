import Foundation

/// Only the successful launch selection is remembered. Permission flags, extra
/// arguments, checkout choices and dirty-tree consent never enter this store.
struct WorkspaceRememberedLaunch: Codable, Equatable {
    let providerID: String
    let modelID: String
    let customModelID: String

    func validated(in providers: [WorkspaceProviderOption]) -> WorkspaceRememberedLaunch? {
        guard let provider = providers.first(where: {
            $0.id == providerID && $0.availability.isAvailable
        }) else { return nil }

        if let model = provider.models.first(where: {
            $0.id == modelID && $0.availability.isAvailable
        }), !model.acceptsCustomIdentifier || !customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .init(
                providerID: provider.id,
                modelID: model.id,
                customModelID: model.acceptsCustomIdentifier ? customModelID : ""
            )
        }

        // A removed model never becomes a custom identifier by guesswork. Keep
        // the provider and offer its one ordinary/default model when unambiguous.
        let ordinaryModels = provider.models.filter {
            $0.availability.isAvailable && !$0.acceptsCustomIdentifier
        }
        guard ordinaryModels.count == 1, let model = ordinaryModels.first else { return nil }
        return .init(providerID: provider.id, modelID: model.id, customModelID: "")
    }
}

@MainActor
final class WorkspaceLaunchPreferencesStore {
    private let defaults: UserDefaults?
    private let key = "byori.workspace.recentLaunchByProject.v1"
    private var selections: [String: WorkspaceRememberedLaunch]

    /// No defaults means an isolated in-memory store for previews and tests.
    /// The live app explicitly supplies its own UserDefaults instance.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: WorkspaceRememberedLaunch].self, from: data) {
            selections = decoded
        } else {
            selections = [:]
        }
    }

    func selection(for projectID: String) -> WorkspaceRememberedLaunch? {
        selections[projectID]
    }

    func remember(_ selection: WorkspaceRememberedLaunch, for projectID: String) {
        guard !projectID.isEmpty else { return }
        selections[projectID] = selection
        if let data = try? JSONEncoder().encode(selections) {
            defaults?.set(data, forKey: key)
        }
    }
}
