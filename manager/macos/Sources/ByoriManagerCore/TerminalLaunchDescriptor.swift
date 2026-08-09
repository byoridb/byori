import Foundation

/// Identifies what a retained terminal session launches. A system shell is
/// deliberately a separate demo target so a missing coding CLI can never
/// silently fall back to an unrestricted shell.
public enum TerminalLaunchTarget: Equatable, Sendable {
    case codingAgent(AgentKind)
    case systemShellDemo
}

/// Records whether a session intentionally follows the vendor CLI's current
/// default or pins an explicit model. `cliDefault` is never serialized into a
/// fake `--model default` argument.
public enum TerminalModelSelection: Equatable, Sendable {
    case cliDefault
    case explicit(String)
}

/// An immutable, shell-free description of one interactive terminal session.
///
/// `arguments` excludes argv[0]. The executable, model, working directory,
/// arguments, and environment are fixed for the lifetime of the descriptor.
public struct TerminalLaunchDescriptor: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: TerminalLaunchTarget
    public let modelSelection: TerminalModelSelection?
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL

    public var model: String? {
        guard case let .explicit(model) = modelSelection else { return nil }
        return model
    }

    public var environmentArray: [String] {
        environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    }

    init(
        id: UUID,
        target: TerminalLaunchTarget,
        modelSelection: TerminalModelSelection?,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL
    ) {
        self.id = id
        self.target = target
        self.modelSelection = modelSelection
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public enum TerminalLaunchDescriptorError: LocalizedError, Equatable {
    case invalidModel
    case modelNotSupported(String)
    case invalidArgument(String)
    case invalidWorkingDirectory(String)
    case missingExecutable(String)
    case invalidExecutable(String)
    case invalidEnvironmentKey(String)
    case invalidEnvironmentValue(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument:
            return "추가 실행 인자는 비어 있지 않은 512바이트 이하의 한 줄이어야 합니다."
        case let .modelNotSupported(name):
            return "\(name)에는 Byori가 모델을 지정할 수 없습니다. CLI 기본 모델로 실행해 주세요."
        case .invalidModel:
            return "모델 이름이 비어 있거나 안전한 CLI 값 형식이 아닙니다."
        case let .invalidWorkingDirectory(path):
            return "세션 작업 디렉터리를 찾을 수 없습니다: \(path)"
        case let .missingExecutable(name):
            return "\(name) CLI를 찾을 수 없습니다. shell로 자동 대체하지 않습니다."
        case let .invalidExecutable(path):
            return "실행 가능한 파일이 아닙니다: \(path)"
        case let .invalidEnvironmentKey(key):
            return "환경 변수 이름이 올바르지 않습니다: \(key)"
        case let .invalidEnvironmentValue(key):
            return "환경 변수 값에 NUL 문자가 포함되어 있습니다: \(key)"
        }
    }
}

/// Builds the exact interactive argv used by the macOS terminal layer.
/// No command is passed through a shell or parsed from a command string.
public struct TerminalLaunchDescriptorFactory {
    private let paths: ManagerPaths
    private let baseEnvironment: [String: String]
    private let fileManager: FileManager
    private let executableResolver: (String) -> URL?

    public init(
        paths: ManagerPaths = .applicationDefault(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.init(
            paths: paths,
            environment: environment,
            fileManager: fileManager,
            executableResolver: { paths.executable(named: $0) }
        )
    }

    init(
        paths: ManagerPaths,
        environment: [String: String],
        fileManager: FileManager,
        executableResolver: @escaping (String) -> URL?
    ) {
        self.paths = paths
        self.baseEnvironment = environment
        self.fileManager = fileManager
        self.executableResolver = executableResolver
    }

    public func codingAgent(
        _ provider: AgentKind,
        model: String? = nil,
        workingDirectory: URL,
        sessionID: UUID = UUID(),
        executableOverride: URL? = nil,
        environmentOverrides: [String: String] = [:],
        additionalArguments: [String] = []
    ) throws -> TerminalLaunchDescriptor {
        let descriptor = provider.descriptor
        let modelSelection: TerminalModelSelection
        if let model {
            // A model flag is only passed to a CLI known to accept one. Sending
            // `--model` to a CLI that does not take it turns a session launch
            // into an argument-parsing error the user cannot act on.
            guard descriptor.supportsModelFlag else {
                throw TerminalLaunchDescriptorError.modelNotSupported(descriptor.displayName)
            }
            modelSelection = .explicit(try validateModel(model))
        } else {
            modelSelection = .cliDefault
        }
        let directory = try validateDirectory(workingDirectory)
        let executable = try resolveExecutable(
            executableOverride,
            defaultName: descriptor.executableName
        )
        let environment = try makeEnvironment(overrides: environmentOverrides)

        var arguments: [String] = []
        if case let .explicit(model) = modelSelection {
            arguments.append(contentsOf: ["--model", model])
        }
        switch descriptor.launchArguments {
        case .none:
            break
        case .claudeSessionID:
            arguments.append(contentsOf: [
                "--session-id", sessionID.uuidString.lowercased(),
            ])
        case .codexWorkingDirectory:
            arguments.append(contentsOf: ["--cd", directory.path])
        }
        // Appended last so a caller-supplied flag wins where a CLI takes the
        // final occurrence, and so Byori's own arguments stay recognisable in
        // the recorded descriptor.
        arguments.append(contentsOf: try additionalArguments.map(validateArgument))

        return TerminalLaunchDescriptor(
            id: sessionID,
            target: .codingAgent(provider),
            modelSelection: modelSelection,
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: directory
        )
    }

    /// Creates an explicit local-shell demo. This API is never called as a
    /// fallback from `codingAgent`.
    public func systemShellDemo(
        workingDirectory: URL,
        sessionID: UUID = UUID(),
        executable: URL = URL(fileURLWithPath: "/bin/zsh"),
        environmentOverrides: [String: String] = [:]
    ) throws -> TerminalLaunchDescriptor {
        let directory = try validateDirectory(workingDirectory)
        let shell = try validateExecutable(executable)
        let environment = try makeEnvironment(overrides: environmentOverrides)

        return TerminalLaunchDescriptor(
            id: sessionID,
            target: .systemShellDemo,
            modelSelection: nil,
            executable: shell,
            arguments: ["-l"],
            environment: environment,
            workingDirectory: directory
        )
    }

    /// Extra flags are handed to the CLI as separate `argv` entries and never go
    /// through a shell, so quoting and metacharacters carry no meaning here. The
    /// checks that remain are the ones `execve` cannot express: a NUL would
    /// truncate the argument, and a newline would make the recorded launch
    /// unreadable in logs and the activity list.
    private func validateArgument(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r") else {
            throw TerminalLaunchDescriptorError.invalidArgument(value)
        }
        return value
    }

    /// Splits a typed argument line into `argv` entries, honouring double quotes
    /// so a path with a space survives. Nothing else about shell syntax applies:
    /// no expansion, no globbing, no operators.
    public static func splitArguments(_ line: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var isQuoted = false
        var hasContent = false
        for character in line {
            if character == "\"" {
                isQuoted.toggle()
                hasContent = true
            } else if character.isWhitespace && !isQuoted {
                if hasContent { arguments.append(current) }
                current = ""
                hasContent = false
            } else {
                current.append(character)
                hasContent = true
            }
        }
        if hasContent { arguments.append(current) }
        return arguments
    }

    private func validateModel(_ value: String) throws -> String {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(model.startIndex..<model.endIndex, in: model)
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$"#
        guard !model.isEmpty,
              let expression = try? NSRegularExpression(pattern: pattern),
              expression.firstMatch(in: model, range: range) != nil else {
            throw TerminalLaunchDescriptorError.invalidModel
        }
        return model
    }

    private func validateDirectory(_ url: URL) throws -> URL {
        let directory = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              !directory.path.contains("\0"),
              fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TerminalLaunchDescriptorError.invalidWorkingDirectory(url.path)
        }
        return directory
    }

    private func resolveExecutable(_ override: URL?, defaultName: String) throws -> URL {
        if let override {
            return try validateExecutable(override)
        }
        guard let resolved = executableResolver(defaultName) else {
            throw TerminalLaunchDescriptorError.missingExecutable(defaultName)
        }
        return try validateExecutable(resolved)
    }

    private func validateExecutable(_ url: URL) throws -> URL {
        let executable = url.standardizedFileURL.resolvingSymlinksInPath()
        guard executable.isFileURL,
              executable.path.hasPrefix("/"),
              !executable.path.contains("\0"),
              fileManager.isExecutableFile(atPath: executable.path) else {
            throw TerminalLaunchDescriptorError.invalidExecutable(url.path)
        }
        return executable
    }

    private func makeEnvironment(overrides: [String: String]) throws -> [String: String] {
        var environment = baseEnvironment
        for (key, value) in overrides {
            try validateEnvironment(key: key, value: value)
            environment[key] = value
        }
        for (key, value) in environment {
            try validateEnvironment(key: key, value: value)
        }

        // SwiftTerm's default environment intentionally omits PATH. Coding
        // agents need it to run tools in the selected worktree, so use the
        // same trusted search path as ManagerPaths and fix terminal identity.
        //
        // GUI launches can inherit NO_COLOR (notably when Byori is started by
        // another coding tool). Claude and other TUIs treat the mere presence
        // of that key as an instruction to suppress ANSI output, even though
        // this is a real color-capable PTY. Normalize only color-suppression
        // variables here; do not force color for arbitrary non-interactive
        // child commands.
        for key in [
            "NO_COLOR",
            "NO_COLOUR",
            "NODE_DISABLE_COLORS",
            "FORCE_COLOR",
            "CLICOLOR_FORCE",
        ] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = paths.processPath
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["CLICOLOR"] = "1"
        if environment["LANG"]?.isEmpty != false {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment
    }

    private func validateEnvironment(key: String, value: String) throws {
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        guard !key.isEmpty,
              key.count <= 255,
              let expression = try? NSRegularExpression(pattern: pattern),
              expression.firstMatch(in: key, range: range) != nil else {
            throw TerminalLaunchDescriptorError.invalidEnvironmentKey(key)
        }
        guard !value.contains("\0") else {
            throw TerminalLaunchDescriptorError.invalidEnvironmentValue(key)
        }
    }
}
