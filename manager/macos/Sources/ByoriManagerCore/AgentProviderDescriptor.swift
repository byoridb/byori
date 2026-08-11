import Foundation

/// How Byori installs a CLI, when it can.
///
/// A missing method is not a gap to fill in later with a guess: these run a
/// shell pipeline fetched over the network, so one is only listed for a CLI
/// whose official install command has actually been confirmed.
public enum AgentInstallMethod: Equatable, Sendable {
    case shellPipeline(command: String, shell: String)

    public var command: String {
        switch self {
        case let .shellPipeline(command, _): return command
        }
    }

    public var shell: String {
        switch self {
        case let .shellPipeline(_, shell): return shell
        }
    }
}

/// The shape of a CLI's `mcp` subcommands.
///
/// Every case here was read off the CLI's own `--help`. There is deliberately no
/// generic fallback: registering an MCP server with invented flags would either
/// fail loudly or, worse, write a half-formed entry into the user's config.
public enum AgentMCPCommandStyle: Equatable, Sendable {
    /// `mcp add --transport stdio --scope user <name> -- <command>`
    case claude
    /// `mcp add <name> -- <command>`
    case codex
    /// `mcp add --scope user --transport stdio <name> <command>`
    case gemini

    public func addArguments(name: String, command: String) -> [String] {
        switch self {
        case .claude:
            return ["mcp", "add", "--transport", "stdio", "--scope", "user", name, "--", command]
        case .codex:
            return ["mcp", "add", name, "--", command]
        case .gemini:
            // Takes the command as a positional, so no `--` separator.
            return ["mcp", "add", "--scope", "user", "--transport", "stdio", name, command]
        }
    }

    public func removeArguments(name: String) -> [String] {
        switch self {
        case .claude:
            return ["mcp", "remove", "--scope", "user", name]
        case .codex:
            return ["mcp", "remove", name]
        case .gemini:
            // `--scope` takes a value and defaults to `project`; the removal has
            // to name the same scope the registration used or it silently
            // removes nothing.
            return ["mcp", "remove", "--scope", "user", name]
        }
    }

    /// How a registration is confirmed after it is written.
    ///
    /// Registering without confirming is not an option here — the whole point of
    /// the connect flow is that it reports a verified state — but the CLIs do
    /// not agree on how to ask.
    public var verification: AgentMCPVerification {
        switch self {
        case .claude:
            // `mcp get` also reports the scope, and Byori requires user scope.
            return .cliGet(requiresUserScope: true)
        case .codex:
            return .cliGet(requiresUserScope: false)
        case .gemini:
            // Gemini CLI 0.37 has no `mcp get`, and `mcp list` prints nothing
            // even with a server configured. Its settings file is the only
            // thing that actually answers the question.
            return .settingsJSON(serversKey: "mcpServers", commandKey: "command")
        }
    }
}

public enum AgentMCPVerification: Equatable, Sendable {
    case cliGet(requiresUserScope: Bool)
    case settingsJSON(serversKey: String, commandKey: String)
}

/// Extra launch arguments a CLI needs beyond an optional model flag.
public enum AgentLaunchArguments: Equatable, Sendable {
    case none
    /// Claude accepts the session id Byori generated, which is what lets a
    /// session be reattached later.
    case claudeSessionID
    /// Codex takes its working directory as a flag rather than inheriting it.
    case codexWorkingDirectory
}

/// Everything Byori knows how to do with one coding CLI.
///
/// `install`, `mcp` and `skill` are optional on purpose. A CLI Byori can launch
/// but cannot wire up is a useful thing to offer — it is not a reason to leave
/// the CLI out — but the difference has to be visible rather than discovered
/// when a button silently does nothing.
public struct AgentProviderDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let executableName: String
    public let systemImage: String
    public let install: AgentInstallMethod?
    public let mcp: AgentMCPCommandStyle?
    /// Directory, relative to the user's home, this CLI reads skills from.
    ///
    /// The root rather than one skill's file: Byori manages more than one skill,
    /// and a per-skill path would have to be repeated for each of them.
    public let skillsRootRelativePath: String?
    public let supportsModelFlag: Bool
    public let launchArguments: AgentLaunchArguments
    /// Said in the UI wherever a capability is missing, so "unsupported" never
    /// reads as "broken".
    public let limitations: String?

    public var managesMCP: Bool { mcp != nil }
    public var managesSkill: Bool { skillsRootRelativePath != nil }
    public var canInstall: Bool { install != nil }

    /// True when Byori drives every integration it has. Used by the UI to sort
    /// fully-wired CLIs above launch-only ones.
    public var isFullyIntegrated: Bool { managesMCP && managesSkill && canInstall }

    public init(
        id: String,
        displayName: String,
        executableName: String,
        systemImage: String,
        install: AgentInstallMethod?,
        mcp: AgentMCPCommandStyle?,
        skillsRootRelativePath: String?,
        supportsModelFlag: Bool,
        launchArguments: AgentLaunchArguments,
        limitations: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.executableName = executableName
        self.systemImage = systemImage
        self.install = install
        self.mcp = mcp
        self.skillsRootRelativePath = skillsRootRelativePath
        self.supportsModelFlag = supportsModelFlag
        self.launchArguments = launchArguments
        self.limitations = limitations
    }
}

public extension AgentKind {
    var descriptor: AgentProviderDescriptor { AgentProviderCatalog.descriptor(for: self) }

    var displayName: String { descriptor.displayName }
    var executableName: String { descriptor.executableName }
}

/// The single place a coding CLI is described.
///
/// This replaced per-capability `switch` statements spread across install, MCP
/// registration, skill sync, launch and the settings UI. Adding a CLI used to
/// mean finding all of them; leaving one out meant a provider that looked
/// supported and quietly was not.
public enum AgentProviderCatalog {
    public static func descriptor(for kind: AgentKind) -> AgentProviderDescriptor {
        switch kind {
        case .claude:
            return AgentProviderDescriptor(
                id: "claude",
                displayName: "Claude Code",
                executableName: "claude",
                systemImage: "sparkles",
                install: .shellPipeline(
                    command: "/usr/bin/curl -fsSL https://claude.ai/install.sh | /bin/bash",
                    shell: "/bin/bash"
                ),
                mcp: .claude,
                skillsRootRelativePath: ".claude/skills",
                supportsModelFlag: true,
                launchArguments: .claudeSessionID,
                limitations: nil
            )
        case .codex:
            return AgentProviderDescriptor(
                id: "codex",
                displayName: "Codex",
                executableName: "codex",
                systemImage: "chevron.left.forwardslash.chevron.right",
                install: .shellPipeline(
                    command: "/usr/bin/curl -fsSL https://chatgpt.com/codex/install.sh | /bin/sh",
                    shell: "/bin/sh"
                ),
                mcp: .codex,
                skillsRootRelativePath: ".agents/skills",
                supportsModelFlag: true,
                launchArguments: .codexWorkingDirectory,
                limitations: nil
            )
        case .gemini:
            return AgentProviderDescriptor(
                id: "gemini",
                displayName: "Gemini CLI",
                executableName: "gemini",
                systemImage: "diamond",
                // Gemini CLI is distributed through package managers rather than
                // a single official install script, so Byori detects it and
                // leaves installing it to the user.
                install: nil,
                mcp: .gemini,
                // It reads GEMINI.md context files, not a skills directory of
                // the shape Byori installs.
                skillsRootRelativePath: nil,
                supportsModelFlag: true,
                launchArguments: .none,
                limitations: "Byori does not install this CLI or sync a Skill to it. MCP is connected."
            )
        case .cursorAgent:
            return AgentProviderDescriptor(
                id: "cursor-agent",
                displayName: "Cursor CLI",
                executableName: "cursor-agent",
                systemImage: "cursorarrow.rays",
                install: nil,
                // Left unset rather than guessed: see AgentMCPCommandStyle.
                mcp: nil,
                skillsRootRelativePath: nil,
                supportsModelFlag: false,
                launchArguments: .none,
                limitations: "Byori launches this CLI only. Install it and configure MCP yourself."
            )
        case .opencode:
            return AgentProviderDescriptor(
                id: "opencode",
                displayName: "opencode",
                executableName: "opencode",
                systemImage: "terminal",
                install: nil,
                mcp: nil,
                skillsRootRelativePath: nil,
                supportsModelFlag: false,
                launchArguments: .none,
                limitations: "Byori launches this CLI only. Install it and configure MCP yourself."
            )
        }
    }
}
