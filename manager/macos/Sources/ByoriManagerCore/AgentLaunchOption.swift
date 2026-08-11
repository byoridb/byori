import Foundation

/// A launch option Byori offers as a control instead of making the user
/// remember a flag.
///
/// Every entry here was read off the CLI's own `--help`, the same rule the
/// install and MCP catalogues follow. An invented flag would turn a session
/// launch into an argument-parsing error the user cannot act on, and a guessed
/// *permission* flag would be worse than that: it could either fail to loosen
/// what the user asked for, or loosen something they did not.
public struct AgentLaunchOption: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Passed alone when selected, e.g. `--dangerously-skip-permissions`.
        case flag
        /// Passed as `flag value`, with `values` exactly as the CLI lists them.
        case choice(values: [String])
    }

    public let id: String
    public let title: String
    public let detail: String
    public let flag: String
    public let kind: Kind
    /// Marked in the UI and never preselected. These remove the confirmation
    /// step that stands between an agent and the user's machine.
    public let isDangerous: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        flag: String,
        kind: Kind,
        isDangerous: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.flag = flag
        self.kind = kind
        self.isDangerous = isDangerous
    }

    /// The argv fragment this option contributes. `nil` when nothing was chosen,
    /// so an untouched option adds no arguments at all.
    public func arguments(selection: String?) -> [String] {
        switch kind {
        case .flag:
            return selection == nil ? [] : [flag]
        case let .choice(values):
            guard let selection, values.contains(selection) else { return [] }
            return [flag, selection]
        }
    }
}

public enum AgentLaunchOptionCatalog {
    /// Read from `claude --help` and `codex --help` on 2026-08-11. A CLI that
    /// gains or renames a flag needs this updated; nothing is inferred.
    public static func options(for id: String) -> [AgentLaunchOption] {
        switch id {
        case "claude":
            return [
                AgentLaunchOption(
                    id: "claude.dangerously-skip-permissions",
                    title: "Skip permission checks",
                    detail: "Bypass all permission checks. The agent acts without asking.",
                    flag: "--dangerously-skip-permissions",
                    kind: .flag,
                    isDangerous: true
                ),
                AgentLaunchOption(
                    id: "claude.permission-mode",
                    title: "Permission mode",
                    detail: "How the session asks before acting.",
                    flag: "--permission-mode",
                    kind: .choice(values: [
                        "manual", "acceptEdits", "auto", "dontAsk", "plan", "bypassPermissions",
                    ])
                ),
            ]
        case "codex":
            return [
                AgentLaunchOption(
                    id: "codex.dangerously-bypass",
                    title: "Bypass approvals and sandbox",
                    detail: "Skips every confirmation and runs commands unsandboxed. "
                        + "Codex itself calls this extremely dangerous.",
                    flag: "--dangerously-bypass-approvals-and-sandbox",
                    kind: .flag,
                    isDangerous: true
                ),
                AgentLaunchOption(
                    id: "codex.sandbox",
                    title: "Sandbox",
                    detail: "What model-generated commands are allowed to touch.",
                    flag: "--sandbox",
                    kind: .choice(values: ["read-only", "workspace-write", "danger-full-access"])
                ),
                AgentLaunchOption(
                    id: "codex.ask-for-approval",
                    title: "Approval policy",
                    detail: "When the model must ask before running a command.",
                    flag: "--ask-for-approval",
                    kind: .choice(values: ["untrusted", "on-request", "never"])
                ),
            ]
        default:
            // A custom provider is described by the user, so Byori knows nothing
            // about its flags. The free-form arguments field still applies.
            return []
        }
    }
}

public enum AgentLaunchArgumentComposer {
    /// Chosen options first, then whatever the user typed.
    ///
    /// A CLI that reads a repeated flag takes the last occurrence, so the typed
    /// field wins over a control — someone who wrote the flag out by hand is
    /// being more specific than someone who left a toggle alone. An option whose
    /// flag already appears in the typed text is skipped rather than passed
    /// twice, so argv never carries the two disagreeing.
    public static func arguments(
        options: [AgentLaunchOption],
        selections: [String: String],
        typed: [String]
    ) -> [String] {
        var chosen: [String] = []
        for option in options {
            let arguments = option.arguments(selection: selections[option.id])
            guard !arguments.isEmpty, !typed.contains(option.flag) else { continue }
            chosen.append(contentsOf: arguments)
        }
        return chosen + typed
    }
}
