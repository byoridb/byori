import Foundation

/// A coding CLI the user registered themselves.
///
/// Byori launches it and nothing more: it does not install it, register MCP for
/// it, or sync a Skill to it, because it has no way to know how any of that
/// works for a CLI it has never seen. That is the whole point of the tier —
/// breadth without pretending to integrations that were never verified.
public struct CustomAgentProvider: Identifiable, Equatable, Codable, Sendable {
    public static let maximumNameLength = 60
    public static let maximumArguments = 32

    public let id: String
    public let displayName: String
    public let executablePath: String
    /// Always passed, ahead of anything typed per session.
    public let defaultArguments: [String]

    public var executableURL: URL { URL(fileURLWithPath: executablePath) }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case executablePath = "executable_path"
        case defaultArguments = "default_arguments"
    }

    public init(id: String, displayName: String, executablePath: String, defaultArguments: [String]) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.defaultArguments = defaultArguments
    }
}

public enum CustomAgentProviderError: LocalizedError, Equatable {
    case invalidName
    case invalidExecutable(String)
    case duplicateName(String)
    case reservedIdentifier(String)
    case tooManyArguments
    case invalidArgument
    case notFound(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "CLI 이름은 1~\(CustomAgentProvider.maximumNameLength)자여야 하고 줄바꿈을 포함할 수 없습니다."
        case let .invalidExecutable(path):
            return "실행 가능한 파일이 아닙니다: \(path)"
        case let .duplicateName(name):
            return "같은 이름의 CLI가 이미 등록되어 있습니다: \(name)"
        case let .reservedIdentifier(name):
            return "\(name)은(는) Byori가 기본 제공하는 CLI 이름입니다. 다른 이름을 사용해 주세요."
        case .tooManyArguments:
            return "기본 인자는 \(CustomAgentProvider.maximumArguments)개까지 지정할 수 있습니다."
        case .invalidArgument:
            return "기본 인자에 NUL이나 줄바꿈을 넣을 수 없습니다."
        case let .notFound(id):
            return "등록된 CLI를 찾을 수 없습니다: \(id)"
        case let .persistence(message):
            return "등록한 CLI 목록을 저장하지 못했습니다: \(message)"
        }
    }
}

/// Stores user-registered CLIs next to the manager's other state.
///
/// Reads never throw on a damaged file: a provider list that cannot be parsed
/// must not stop the app from launching the CLIs it does know about. Writes are
/// atomic so a crash mid-save cannot leave the list half-written.
public actor CustomAgentProviderStore {
    private let file: URL
    private let fileManager: FileManager

    public init(paths: ManagerPaths, fileManager: FileManager = .default) {
        self.file = paths.managerHome.appendingPathComponent("custom-agents.json")
        self.fileManager = fileManager
    }

    public func providers() -> [CustomAgentProvider] {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([CustomAgentProvider].self, from: data) else {
            return []
        }
        return stored
    }

    @discardableResult
    public func add(
        displayName: String,
        executablePath: String,
        defaultArguments: [String] = []
    ) throws -> CustomAgentProvider {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= CustomAgentProvider.maximumNameLength,
              !name.contains("\n"), !name.contains("\r"), !name.contains("\0") else {
            throw CustomAgentProviderError.invalidName
        }
        // A custom provider's id shares a namespace with the built-in ones,
        // because a session records only the provider id. Colliding would make a
        // stored session ambiguous.
        let id = Self.identifier(for: name)
        guard AgentKind(rawValue: id) == nil else {
            throw CustomAgentProviderError.reservedIdentifier(name)
        }
        guard defaultArguments.count <= CustomAgentProvider.maximumArguments else {
            throw CustomAgentProviderError.tooManyArguments
        }
        guard defaultArguments.allSatisfy({
            !$0.isEmpty && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r")
        }) else {
            throw CustomAgentProviderError.invalidArgument
        }
        let executable = try Self.validateExecutable(executablePath, fileManager: fileManager)

        var current = providers()
        guard !current.contains(where: { $0.id == id }) else {
            throw CustomAgentProviderError.duplicateName(name)
        }
        let provider = CustomAgentProvider(
            id: id,
            displayName: name,
            executablePath: executable,
            defaultArguments: defaultArguments
        )
        current.append(provider)
        try save(current)
        return provider
    }

    public func remove(id: String) throws {
        var current = providers()
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            throw CustomAgentProviderError.notFound(id)
        }
        current.remove(at: index)
        try save(current)
    }

    public func provider(id: String) -> CustomAgentProvider? {
        providers().first { $0.id == id }
    }

    private func save(_ providers: [CustomAgentProvider]) throws {
        do {
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(providers).write(to: file, options: [.atomic])
        } catch {
            throw CustomAgentProviderError.persistence(error.localizedDescription)
        }
    }

    /// Slugifies the display name. Kept to the same character set the workspace
    /// identifier validator accepts, since the id ends up in persisted sessions.
    static func identifier(for name: String) -> String {
        let mapped = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let slug = collapsed.isEmpty ? "custom" : collapsed
        return "custom-" + String(slug.prefix(64))
    }

    static func validateExecutable(_ path: String, fileManager: FileManager) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix("/"),
              !url.path.contains("\0"),
              fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: url.path) else {
            throw CustomAgentProviderError.invalidExecutable(path)
        }
        return url.path
    }
}
