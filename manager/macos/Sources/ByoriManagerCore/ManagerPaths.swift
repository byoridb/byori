import Foundation

public struct ManagerPaths: Sendable {
    private struct InstalledConfiguration {
        let home: URL
        let httpPort: Int
        let graphPort: Int
        let serviceLabel: String
    }

    public let home: URL
    public let runtimeRoot: URL
    public let byoriHome: URL
    public let httpPort: Int
    public let graphPort: Int
    public let serviceLabel: String

    public var managerHome: URL { home.appendingPathComponent(".byori-manager", isDirectory: true) }
    public var backups: URL { managerHome.appendingPathComponent("backups", isDirectory: true) }
    public var serverBinary: URL { byoriHome.appendingPathComponent("bin/byoridb-server") }
    public var mcpRunner: URL { byoriHome.appendingPathComponent("bin/run-mcp.sh") }
    public var logs: URL { byoriHome.appendingPathComponent("logs", isDirectory: true) }
    public var launchAgent: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(serviceLabel).plist")
    }
    public var installer: URL { runtimeRoot.appendingPathComponent("install.sh") }
    public var skillSource: URL {
        runtimeRoot.appendingPathComponent("adapters/claude/skills/byoridb-memory/SKILL.md")
    }
    public var claudeSkill: URL {
        home.appendingPathComponent(".claude/skills/byoridb-memory/SKILL.md")
    }
    public var codexSkill: URL {
        home.appendingPathComponent(".agents/skills/byoridb-memory/SKILL.md")
    }
    public var claudeConfig: URL { home.appendingPathComponent(".claude.json") }
    public var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    public var legacyCodexSkill: URL {
        home.appendingPathComponent(".codex/skills/byoridb-memory/SKILL.md")
    }

    public init(
        home: URL,
        runtimeRoot: URL,
        byoriHome: URL? = nil,
        httpPort: Int = 19_669,
        graphPort: Int = 9_669,
        serviceLabel: String = "com.byoridb.local"
    ) {
        self.home = home.standardizedFileURL
        self.runtimeRoot = runtimeRoot.standardizedFileURL
        self.byoriHome = (byoriHome ?? home.appendingPathComponent(".byoridb", isDirectory: true))
            .standardizedFileURL
        self.httpPort = httpPort
        self.graphPort = graphPort
        self.serviceLabel = serviceLabel
    }

    public static func applicationDefault(
        bundle: Bundle = .main,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ManagerPaths {
        let home = home.standardizedFileURL
        let discovered = discoverInstallation(home: home)
        let configuredHome = environment["BYORIDB_HOME"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        let selectedHome = configuredHome ?? discovered?.home
            ?? home.appendingPathComponent(".byoridb", isDirectory: true)
        let renderedPorts = ports(in: selectedHome)
        let matchesDiscoveredHome = discovered?.home.standardizedFileURL == selectedHome.standardizedFileURL
        return ManagerPaths(
            home: home,
            runtimeRoot: locateRuntime(bundle: bundle),
            byoriHome: selectedHome,
            httpPort: validPort(environment["BYORIDB_HTTP_PORT"])
                ?? renderedPorts.http
                ?? (matchesDiscoveredHome ? discovered?.httpPort : nil)
                ?? 19_669,
            graphPort: validPort(environment["BYORIDB_GRAPH_PORT"])
                ?? renderedPorts.graph
                ?? (matchesDiscoveredHome ? discovered?.graphPort : nil)
                ?? 9_669,
            serviceLabel: validLabel(environment["BYORIDB_LABEL"])
                ?? (matchesDiscoveredHome ? discovered?.serviceLabel : nil)
                ?? "com.byoridb.local"
        )
    }

    private static func discoverInstallation(home: URL) -> InstalledConfiguration? {
        let fileManager = FileManager.default
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: launchAgents,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = entries.filter { $0.pathExtension == "plist" }.sorted { lhs, rhs in
            func rank(_ url: URL) -> Int {
                if url.lastPathComponent == "com.byoridb.local.plist" { return 0 }
                return url.lastPathComponent.lowercased().contains("byori") ? 1 : 2
            }
            let leftRank = rank(lhs)
            let rightRank = rank(rhs)
            return leftRank == rightRank
                ? lhs.lastPathComponent < rhs.lastPathComponent
                : leftRank < rightRank
        }

        for plist in candidates {
            guard let data = try? Data(contentsOf: plist),
                  let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = value as? [String: Any],
                  let label = dictionary["Label"] as? String,
                  let workingDirectory = dictionary["WorkingDirectory"] as? String,
                  let arguments = dictionary["ProgramArguments"] as? [String],
                  arguments.contains(where: { $0.hasSuffix("/bin/run-server.sh") }),
                  let validServiceLabel = validLabel(label) else {
                continue
            }
            let installedHome = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .standardizedFileURL
            guard fileManager.fileExists(
                atPath: installedHome.appendingPathComponent("bin/run-server.sh").path
            ) else { continue }
            let renderedPorts = ports(in: installedHome)
            return InstalledConfiguration(
                home: installedHome,
                httpPort: renderedPorts.http ?? 19_669,
                graphPort: renderedPorts.graph ?? 9_669,
                serviceLabel: validServiceLabel
            )
        }
        return nil
    }

    private static func ports(in installedHome: URL) -> (http: Int?, graph: Int?) {
        let script = installedHome.appendingPathComponent("bin/run-server.sh")
        guard let contents = try? String(contentsOf: script, encoding: .utf8) else {
            return (nil, nil)
        }
        func renderedPort(_ variable: String) -> Int? {
            for line in contents.components(separatedBy: .newlines) where line.contains(variable) {
                guard let tail = line.split(separator: ":").last else { continue }
                let digits = tail.prefix { $0.isNumber }
                if let port = validPort(String(digits)) { return port }
            }
            return nil
        }
        return (
            renderedPort("BYORIDB__SERVER__HTTP_ADDR"),
            renderedPort("BYORIDB__SERVER__GRAPH_ADDR")
        )
    }

    private static func validPort(_ value: String?) -> Int? {
        guard let value, let port = Int(value), (1...65_535).contains(port) else { return nil }
        return port
    }

    private static func validLabel(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    public static func locateRuntime(bundle: Bundle = .main) -> URL {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []

        if let override = environment["BYORI_RUNTIME_ROOT"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("runtime", isDirectory: true))
        }

        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(current)
        candidates.append(current.appendingPathComponent("../..", isDirectory: true))
        candidates.append(current.appendingPathComponent("../../..", isDirectory: true))

        for candidate in candidates.map({ $0.standardizedFileURL }) {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("install.sh").path),
               fileManager.fileExists(atPath: candidate.appendingPathComponent("mcp/byoridb_mcp.py").path) {
                return candidate
            }
        }

        return bundle.resourceURL?.appendingPathComponent("runtime", isDirectory: true)
            ?? current
    }

    public func executable(named name: String) -> URL? {
        let fileManager = FileManager.default
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    public var processPath: String {
        searchDirectories.joined(separator: ":")
    }

    private var searchDirectories: [String] {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var preferred = [
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".volta/bin").path,
            home.appendingPathComponent(".asdf/shims").path,
            home.appendingPathComponent(".pyenv/shims").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let nvmBinRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmBinRoot,
            includingPropertiesForKeys: nil
        ) {
            preferred.append(contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin").path })
        }
        preferred.append(contentsOf: environmentPath.split(separator: ":").map(String.init))

        var seen = Set<String>()
        return preferred.filter { directory in
            guard directory.hasPrefix("/"), !directory.contains("\n") else { return false }
            return seen.insert(directory).inserted
        }
    }
}

public struct ManagedFileInstaller: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func state(source: URL, destination: URL) -> ManagedFileState {
        guard fileManager.fileExists(atPath: destination.path) else { return .missing }
        guard let sourceData = try? Data(contentsOf: source),
              let destinationData = try? Data(contentsOf: destination) else {
            return .outdated
        }
        return sourceData == destinationData ? .current : .outdated
    }

    @discardableResult
    public func install(source: URL, destination: URL, backupRoot: URL) throws -> Bool {
        let sourceData = try Data(contentsOf: source)
        if let existing = try? Data(contentsOf: destination), existing == sourceData {
            return false
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try backup(file: destination, root: backupRoot)
        }
        try sourceData.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        return true
    }

    @discardableResult
    public func remove(destination: URL, backupRoot: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: destination.path) else { return false }
        _ = try backup(file: destination, root: backupRoot)
        try fileManager.removeItem(at: destination)
        removeEmptyParents(from: destination.deletingLastPathComponent())
        return true
    }

    @discardableResult
    public func backup(file: URL, root: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeName = file.path.replacingOccurrences(of: "/", with: "_")
        let destination = root.appendingPathComponent("\(stamp)-\(UUID().uuidString)-\(safeName)")
        try fileManager.copyItem(at: file, to: destination)
        return destination
    }

    public func restore(backup: URL, destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: backup, to: destination)
    }

    private func removeEmptyParents(from start: URL) {
        var current = start
        for _ in 0..<2 {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: current.path), entries.isEmpty else {
                return
            }
            try? fileManager.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }
}
