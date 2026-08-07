import Darwin
import CoreFoundation
import Foundation

public extension ManagerPaths {
    /// Metadata shared with the Byori workspace CLI. This is intentionally
    /// distinct from `byoriHome`, which points at the ByoriDB runtime.
    var workspaceHome: URL {
        home.appendingPathComponent(".byori", isDirectory: true).standardizedFileURL
    }
}

public protocol WorkspaceProjectReading: Sendable {
    func projects() async throws -> [WorkspaceProject]

    /// Returns a non-persisted discovery value only when the durable registry is empty.
    func previewUnregisteredProject(at currentDirectory: URL) async throws -> WorkspaceProjectPreview?
}

public protocol WorkspaceProjectRegistering: Sendable {
    @discardableResult
    func registerProject(at path: URL, memorySpace: String?) async throws -> WorkspaceProject
}

public protocol WorkspaceProjectRemoving: Sendable {
    /// Removes a project from the active trust list without deleting its repository,
    /// ByoriDB space, tasks, or checkout metadata. Re-registering the same canonical
    /// root restores the archived raw record and its stable project identity.
    @discardableResult
    func removeProject(id: String) async throws -> WorkspaceProject
}

public protocol WorkspaceCheckoutVisibilityPersisting: Sendable {
    func hiddenCheckoutPaths(projectID: String) async throws -> Set<String>
    func hideCheckout(projectID: String, at path: URL) async throws
    func unhideCheckout(projectID: String, at path: URL) async throws
}

public actor WorkspaceProjectRegistry:
    WorkspaceProjectReading,
    WorkspaceProjectRegistering,
    WorkspaceProjectRemoving
{
    private static let supportedSchemaVersion = 1
    private static let registryByteLimit = 4 * 1_024 * 1_024
    private static let projectLimit = 10_000

    private struct RegistryState {
        var document: [String: Any]
        var rawProjects: [[String: Any]]
        var rawRemovedProjects: [[String: Any]]
        var projects: [WorkspaceProject]
        var removedProjects: [WorkspaceProject]
    }

    private let home: URL
    private let registryURL: URL
    private let git: any WorkspaceGitInspecting
    private let idGenerator: @Sendable () -> String
    private let now: @Sendable () -> Date
    private let visibilityStore: WorkspaceCheckoutVisibilityStore

    public init(
        home: URL,
        git: any WorkspaceGitInspecting = WorkspaceGitService(),
        idGenerator: @escaping @Sendable () -> String = {
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        },
        now: @escaping @Sendable () -> Date = { Date() },
        visibilityStore: WorkspaceCheckoutVisibilityStore? = nil
    ) {
        self.home = home.standardizedFileURL
        self.registryURL = home.standardizedFileURL.appendingPathComponent("projects.json")
        self.git = git
        self.idGenerator = idGenerator
        self.now = now
        self.visibilityStore = visibilityStore ?? WorkspaceCheckoutVisibilityStore(home: home)
    }

    public func projects() async throws -> [WorkspaceProject] {
        let state = try validatedState(from: readRegistryDocument())
        let registered = state.projects
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
                return lhs.id < rhs.id
            }
        var projects: [WorkspaceProject] = []
        projects.reserveCapacity(registered.count)
        let hiddenPathsByProject = try await visibilityStore.hiddenCheckoutPathsByProject()
        for project in registered {
            let hiddenPaths = hiddenPathsByProject[project.id] ?? []
            projects.append(await discoveringWorktrees(in: project, hiddenPaths: hiddenPaths))
        }
        return projects
    }

    public func previewUnregisteredProject(
        at currentDirectory: URL
    ) async throws -> WorkspaceProjectPreview? {
        guard try validatedState(from: readRegistryDocument()).projects.isEmpty else { return nil }
        let root = try await git.repositoryRoot(at: currentDirectory)
        let remote = try await git.originRemote(at: root).map(Self.sanitizeRemote)
        return WorkspaceProjectPreview(
            name: root.lastPathComponent.isEmpty ? "project" : root.lastPathComponent,
            rootPath: root.path,
            remote: remote
        )
    }

    @discardableResult
    public func registerProject(
        at path: URL,
        memorySpace: String? = nil
    ) async throws -> WorkspaceProject {
        let root = try await git.repositoryRoot(at: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let remote = try await git.originRemote(at: root).map(Self.sanitizeRemote)
        let lockURL = home.appendingPathComponent("locks/projects.lock")

        return try WorkspaceDisk.withExclusiveLock(at: lockURL) {
            var state = try validatedState(from: readRegistryDocument())
            if let existing = state.projects.first(where: {
                Self.canonicalPath($0.rootPath) == root.path
            }) {
                if let memorySpace, memorySpace != existing.memorySpace {
                    throw WorkspaceError.invalidProject(
                        "repository is already registered with memory space \(existing.memorySpace)"
                    )
                }
                return existing
            }

            if let removedIndex = state.removedProjects.firstIndex(where: {
                Self.canonicalPath($0.rootPath) == root.path
            }) {
                guard state.rawProjects.count < Self.projectLimit else {
                    throw WorkspaceError.invalidRegistry("project limit exceeded")
                }
                let removed = state.removedProjects[removedIndex]
                if let memorySpace, memorySpace != removed.memorySpace {
                    throw WorkspaceError.invalidProject(
                        "repository was removed with memory space \(removed.memorySpace)"
                    )
                }
                let rawProject = state.rawRemovedProjects.remove(at: removedIndex)
                state.rawProjects.append(rawProject)
                state.document["projects"] = state.rawProjects
                state.document["removed_projects"] = state.rawRemovedProjects
                try WorkspaceDisk.writeJSONObject(state.document, to: registryURL)
                return removed
            }

            guard state.rawProjects.count < Self.projectLimit else {
                throw WorkspaceError.invalidRegistry("project limit exceeded")
            }

            let projectID = idGenerator()
            try WorkspaceValidation.identifier(projectID, label: "project id")
            guard !state.projects.contains(where: { $0.id == projectID }),
                  !state.removedProjects.contains(where: { $0.id == projectID }) else {
                throw WorkspaceError.invalidProject("generated project id already exists")
            }
            let name = root.lastPathComponent.isEmpty ? "project" : root.lastPathComponent
            let space = try memorySpace.map(Self.validateMemorySpace)
                ?? Self.defaultMemorySpace(projectName: name, projectID: projectID)
            let addedAt = now()
            var rawProject: [String: Any] = [
                "id": projectID,
                "name": name,
                "root": root.path,
                "space": space,
                "remote": remote ?? "",
                "added_at": Self.dateString(addedAt),
            ]
            // Keep the persisted record schema-v1-compatible. SourceTree identity is
            // synthesized additively by the reader until the shared CLI schema evolves.
            state.rawProjects.append(rawProject)
            state.document["schema_version"] = Self.supportedSchemaVersion
            state.document["projects"] = state.rawProjects
            try WorkspaceDisk.writeJSONObject(state.document, to: registryURL)
            rawProject["source_trees"] = NSNull()
            return try decodeProject(rawProject)
        }
    }

    @discardableResult
    public func removeProject(id: String) async throws -> WorkspaceProject {
        try WorkspaceValidation.identifier(id, label: "project id")
        let lockURL = home.appendingPathComponent("locks/projects.lock")
        return try WorkspaceDisk.withExclusiveLock(at: lockURL) {
            var state = try validatedState(from: readRegistryDocument())
            guard let projectIndex = state.projects.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceError.projectNotFound(id)
            }
            guard state.rawRemovedProjects.count < Self.projectLimit else {
                throw WorkspaceError.invalidRegistry("removed project limit exceeded")
            }
            let removed = state.projects.remove(at: projectIndex)
            let rawRemoved = state.rawProjects.remove(at: projectIndex)
            state.rawRemovedProjects.append(rawRemoved)
            state.document["projects"] = state.rawProjects
            state.document["removed_projects"] = state.rawRemovedProjects
            try WorkspaceDisk.writeJSONObject(state.document, to: registryURL)
            return removed
        }
    }

    private func readRegistryDocument() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return [
                "schema_version": Self.supportedSchemaVersion,
                "projects": [[String: Any]](),
                "removed_projects": [[String: Any]](),
            ]
        }
        let data = try WorkspaceDisk.readData(
            at: registryURL,
            byteLimit: Self.registryByteLimit,
            label: "project registry"
        )
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WorkspaceError.invalidRegistry("malformed JSON")
        }
        guard let document = value as? [String: Any], document["projects"] is [Any] else {
            throw WorkspaceError.invalidRegistry("root must contain a projects array")
        }
        return document
    }

    private func validatedState(from document: [String: Any]) throws -> RegistryState {
        let schemaVersion: Int
        if let rawSchemaVersion = document["schema_version"] {
            guard let value = Self.integer(rawSchemaVersion) else {
                throw WorkspaceError.invalidRegistry("schema_version must be an integer")
            }
            schemaVersion = value
        } else {
            schemaVersion = Self.supportedSchemaVersion
        }
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw WorkspaceError.unsupportedProjectSchema(schemaVersion)
        }
        guard let rawProjects = document["projects"] as? [[String: Any]] else {
            throw WorkspaceError.invalidRegistry("projects must contain JSON objects")
        }
        let rawRemovedProjects: [[String: Any]]
        if let value = document["removed_projects"] {
            guard let removed = value as? [[String: Any]] else {
                throw WorkspaceError.invalidRegistry("removed_projects must contain JSON objects")
            }
            rawRemovedProjects = removed
        } else {
            rawRemovedProjects = []
        }
        guard rawProjects.count <= Self.projectLimit,
              rawRemovedProjects.count <= Self.projectLimit else {
            throw WorkspaceError.invalidRegistry("project limit exceeded")
        }

        let projects = try rawProjects.map(decodeProject)
        let removedProjects = try rawRemovedProjects.map(decodeProject)
        let allProjects = projects + removedProjects
        guard Set(allProjects.map(\.id)).count == allProjects.count else {
            throw WorkspaceError.invalidRegistry("project ids must be unique across active and removed projects")
        }
        let roots = allProjects.map { Self.canonicalPath($0.rootPath) }
        guard Set(roots).count == roots.count else {
            throw WorkspaceError.invalidRegistry("project roots must be unique across active and removed projects")
        }
        return RegistryState(
            document: document,
            rawProjects: rawProjects,
            rawRemovedProjects: rawRemovedProjects,
            projects: projects,
            removedProjects: removedProjects
        )
    }

    private func decodeProject(_ raw: [String: Any]) throws -> WorkspaceProject {
        guard let id = Self.boundedString(raw["id"], byteLimit: 128),
              let name = Self.boundedString(raw["name"], byteLimit: 500),
              let root = Self.boundedString(raw["root"], byteLimit: 4_096),
              let space = Self.boundedString(raw["space"], byteLimit: 128),
              let addedAtValue = Self.boundedString(raw["added_at"], byteLimit: 128),
              let addedAt = Self.parseDate(addedAtValue) else {
            throw WorkspaceError.invalidRegistry("project is missing bounded schema-v1 fields")
        }
        try WorkspaceValidation.identifier(id, label: "project id")
        _ = try Self.validateMemorySpace(space)
        guard root.hasPrefix("/") else {
            throw WorkspaceError.invalidRegistry("project root must be absolute")
        }
        let remote = Self.boundedString(raw["remote"], byteLimit: 4_096).flatMap { $0.isEmpty ? nil : $0 }

        let fallbackSourceTreeID = "source-\(id)"
        let sourceTrees: [WorkspaceSourceTree]
        if let rawSourceTrees = raw["source_trees"] as? [[String: Any]], !rawSourceTrees.isEmpty {
            sourceTrees = try rawSourceTrees.prefix(1_000).map { source in
                let sourceID = Self.boundedString(source["id"], byteLimit: 128) ?? fallbackSourceTreeID
                let sourcePath = Self.boundedString(source["path"], byteLimit: 4_096) ?? root
                try WorkspaceValidation.identifier(sourceID, label: "source tree id")
                let worktrees = try Self.decodeWorktrees(source["worktrees"], sourceTreeID: sourceID)
                return WorkspaceSourceTree(
                    id: sourceID,
                    projectID: id,
                    path: sourcePath,
                    worktrees: worktrees
                )
            }
        } else {
            sourceTrees = [WorkspaceSourceTree(
                id: fallbackSourceTreeID,
                projectID: id,
                path: root
            )]
        }

        return WorkspaceProject(
            id: id,
            name: name,
            rootPath: root,
            memorySpace: space,
            remote: remote,
            addedAt: addedAt,
            sourceTrees: sourceTrees
        )
    }

    private static func decodeWorktrees(
        _ value: Any?,
        sourceTreeID: String
    ) throws -> [WorkspaceWorktree] {
        guard let values = value as? [[String: Any]] else { return [] }
        guard values.count <= 2_000 else {
            throw WorkspaceError.invalidRegistry("worktree limit exceeded")
        }
        return try values.map { raw in
            guard let id = boundedString(raw["id"], byteLimit: 128),
                  let path = boundedString(raw["path"], byteLimit: 4_096) else {
                throw WorkspaceError.invalidRegistry("worktree is missing id or path")
            }
            try WorkspaceValidation.identifier(id, label: "worktree id")
            return WorkspaceWorktree(
                id: id,
                sourceTreeID: sourceTreeID,
                path: path,
                branch: boundedString(raw["branch"], byteLimit: 1_024),
                baseRevision: boundedString(raw["base_revision"] ?? raw["base_sha"], byteLimit: 256),
                isManaged: raw["managed"] as? Bool ?? false
            )
        }
    }

    private static func validateMemorySpace(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 64,
              let first = value.unicodeScalars.first,
              ((65...90).contains(first.value) || (97...122).contains(first.value) || first == "_"),
              value.unicodeScalars.dropFirst().allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar == "_"
              }) else {
            throw WorkspaceError.invalidProject("memory space must be a safe identifier")
        }
        return value
    }

    private static func defaultMemorySpace(projectName: String, projectID: String) -> String {
        let scalars = projectName.lowercased().unicodeScalars.map { scalar -> Character in
            if (48...57).contains(scalar.value) || (97...122).contains(scalar.value) {
                return Character(String(scalar))
            }
            return "_"
        }
        let slug = String(scalars).split(separator: "_").filter { !$0.isEmpty }.joined(separator: "_")
        let boundedSlug = String((slug.isEmpty ? "project" : slug).prefix(36))
        return "byori_\(boundedSlug)_\(projectID.prefix(8))"
    }

    private static func sanitizeRemote(_ value: String) -> String {
        var sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        if sanitized.contains("://"), var components = URLComponents(string: sanitized) {
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            sanitized = components.string ?? ""
        } else if sanitized.contains("@"), sanitized.contains(":"),
                  let separator = sanitized.firstIndex(of: "@") {
            sanitized = String(sanitized[sanitized.index(after: separator)...])
        }
        if sanitized.hasSuffix(".git") {
            sanitized.removeLast(4)
        }
        return String(sanitized.prefix(4_096))
    }

    /// Discovers Git worktrees at read time so the shared schema-v1 registry
    /// remains an explicit trust list rather than a cache of mutable Git state.
    /// A manually authored non-Git project, or a temporarily unavailable Git
    /// checkout, retains its decoded source-tree/worktree shape unchanged.
    private func discoveringWorktrees(
        in project: WorkspaceProject,
        hiddenPaths: Set<String>
    ) async -> WorkspaceProject {
        let sourceTreePaths = Set(project.sourceTrees.map { Self.canonicalPath($0.path) })
        let persistedOwnerByPath = project.sourceTrees.reduce(into: [String: String]()) { owners, sourceTree in
            for worktree in sourceTree.worktrees {
                owners[Self.canonicalPath(worktree.path)] = sourceTree.id
            }
        }
        var assignedPaths = Set<String>()
        var usedIDs = Set(project.sourceTrees.map(\.id))
        usedIDs.formUnion(project.sourceTrees.flatMap { $0.worktrees.map(\.id) })
        var sourceTrees: [WorkspaceSourceTree] = []
        sourceTrees.reserveCapacity(project.sourceTrees.count)

        for sourceTree in project.sourceTrees {
            let discovered: [WorkspaceGitWorktreeSnapshot]
            do {
                discovered = try await git.worktrees(
                    at: URL(fileURLWithPath: sourceTree.path, isDirectory: true)
                )
            } catch {
                sourceTrees.append(WorkspaceSourceTree(
                    id: sourceTree.id,
                    projectID: sourceTree.projectID,
                    path: sourceTree.path,
                    worktrees: sourceTree.worktrees.filter {
                        !hiddenPaths.contains(Self.canonicalPath($0.path))
                    }
                ))
                continue
            }

            let persistedByPath = Dictionary(
                sourceTree.worktrees.map { (Self.canonicalPath($0.path), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var worktrees: [WorkspaceWorktree] = []
            worktrees.reserveCapacity(discovered.count + sourceTree.worktrees.count)

            for checkout in discovered {
                let path = Self.canonicalPath(checkout.path)
                guard !hiddenPaths.contains(path),
                      !sourceTreePaths.contains(path),
                      persistedOwnerByPath[path].map({ $0 == sourceTree.id }) ?? true,
                      assignedPaths.insert(path).inserted else {
                    continue
                }
                let persisted = persistedByPath[path]
                let id: String
                if let persisted {
                    id = persisted.id
                } else {
                    id = Self.uniqueWorktreeID(
                        projectID: project.id,
                        path: path,
                        usedIDs: &usedIDs
                    )
                }
                usedIDs.insert(id)
                worktrees.append(WorkspaceWorktree(
                    id: id,
                    sourceTreeID: sourceTree.id,
                    path: path,
                    branch: checkout.branch,
                    baseRevision: persisted?.baseRevision,
                    isManaged: persisted?.isManaged ?? Self.isManagedWorktree(path, home: home)
                ))
            }

            for persisted in sourceTree.worktrees {
                let path = Self.canonicalPath(persisted.path)
                guard !hiddenPaths.contains(path),
                      assignedPaths.insert(path).inserted else { continue }
                worktrees.append(persisted)
            }
            sourceTrees.append(WorkspaceSourceTree(
                id: sourceTree.id,
                projectID: sourceTree.projectID,
                path: sourceTree.path,
                worktrees: worktrees
            ))
        }

        return WorkspaceProject(
            id: project.id,
            name: project.name,
            rootPath: project.rootPath,
            memorySpace: project.memorySpace,
            remote: project.remote,
            addedAt: project.addedAt,
            sourceTrees: sourceTrees
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func isManagedWorktree(_ path: String, home: URL) -> Bool {
        let managedRoot = canonicalPath(home.appendingPathComponent("worktrees", isDirectory: true).path)
        return path == managedRoot || path.hasPrefix(managedRoot + "/")
    }

    private static func uniqueWorktreeID(
        projectID: String,
        path: String,
        usedIDs: inout Set<String>
    ) -> String {
        var salt = 0
        while true {
            let pathIdentity = salt == 0 ? path : path + "#\(salt)"
            let identity = projectID + "\0" + pathIdentity
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in identity.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            let rawHex = String(hash, radix: 16, uppercase: false)
            let hex = String(repeating: "0", count: max(0, 16 - rawHex.count)) + rawHex
            let candidate = "worktree-\(projectID.prefix(80))-\(hex)"
            if !usedIDs.contains(candidate) {
                return candidate
            }
            salt += 1
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func boundedString(_ value: Any?, byteLimit: Int) -> String? {
        guard let value = value as? String, value.utf8.count <= byteLimit,
              !value.contains("\u{0}") else { return nil }
        return value
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// App-owned visibility preferences for Git checkouts. Hiding a checkout is a
/// presentation operation only: this store never removes a directory, Git
/// worktree, branch, task, session, or ByoriDB memory space.
public actor WorkspaceCheckoutVisibilityStore: WorkspaceCheckoutVisibilityPersisting {
    private struct CheckoutKey: Hashable {
        let projectID: String
        let path: String
    }

    private struct VisibilityState {
        var document: [String: Any]
        var rawEntries: [[String: Any]]
        var keys: Set<CheckoutKey>
    }

    private static let schemaVersion = 1
    private static let fileByteLimit = 4 * 1_024 * 1_024
    private static let entryLimit = 10_000
    private static let pathByteLimit = 4_096

    private let stateURL: URL
    private let lockURL: URL

    public init(home: URL) {
        let standardizedHome = home.standardizedFileURL
        self.stateURL = standardizedHome
            .appendingPathComponent("manager", isDirectory: true)
            .appendingPathComponent("checkout-visibility.json")
        self.lockURL = standardizedHome.appendingPathComponent("locks/checkout-visibility.lock")
    }

    public func hiddenCheckoutPaths(projectID: String) async throws -> Set<String> {
        try WorkspaceValidation.identifier(projectID, label: "project id")
        let state = try readState()
        return Set(
            state.keys.lazy
                .filter { $0.projectID == projectID }
                .map(\.path)
        )
    }

    func hiddenCheckoutPathsByProject() throws -> [String: Set<String>] {
        let state = try readState()
        return state.keys.reduce(into: [String: Set<String>]()) { result, key in
            result[key.projectID, default: []].insert(key.path)
        }
    }

    public func hideCheckout(projectID: String, at path: URL) async throws {
        try WorkspaceValidation.identifier(projectID, label: "project id")
        let canonicalPath = try Self.canonicalPath(for: path)
        try WorkspaceDisk.withExclusiveLock(at: lockURL) {
            var state = try readState()
            let key = CheckoutKey(projectID: projectID, path: canonicalPath)
            guard !state.keys.contains(key) else { return }
            guard state.rawEntries.count < Self.entryLimit else {
                throw WorkspaceError.invalidRegistry("hidden checkout limit exceeded")
            }
            state.rawEntries.append([
                "project_id": projectID,
                "path": canonicalPath,
            ])
            state.document["schema_version"] = Self.schemaVersion
            state.document["hidden_checkouts"] = state.rawEntries
            try WorkspaceDisk.writeJSONObject(state.document, to: stateURL)
        }
    }

    public func unhideCheckout(projectID: String, at path: URL) async throws {
        try WorkspaceValidation.identifier(projectID, label: "project id")
        let canonicalPath = try Self.canonicalPath(for: path)
        try WorkspaceDisk.withExclusiveLock(at: lockURL) {
            var state = try readState()
            let key = CheckoutKey(projectID: projectID, path: canonicalPath)
            guard state.keys.contains(key) else { return }
            state.rawEntries.removeAll { raw in
                raw["project_id"] as? String == projectID
                    && raw["path"] as? String == canonicalPath
            }
            state.document["schema_version"] = Self.schemaVersion
            state.document["hidden_checkouts"] = state.rawEntries
            try WorkspaceDisk.writeJSONObject(state.document, to: stateURL)
        }
    }

    private func readState() throws -> VisibilityState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return VisibilityState(
                document: [
                    "schema_version": Self.schemaVersion,
                    "hidden_checkouts": [[String: Any]](),
                ],
                rawEntries: [],
                keys: []
            )
        }
        let data = try WorkspaceDisk.readData(
            at: stateURL,
            byteLimit: Self.fileByteLimit,
            label: "checkout visibility"
        )
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WorkspaceError.invalidRegistry("checkout visibility JSON is malformed")
        }
        guard let document = value as? [String: Any] else {
            throw WorkspaceError.invalidRegistry("checkout visibility root must be an object")
        }
        guard let rawSchemaVersion = document["schema_version"],
              let schemaVersion = Self.integer(rawSchemaVersion) else {
            throw WorkspaceError.invalidRegistry("checkout visibility schema_version must be an integer")
        }
        guard schemaVersion == Self.schemaVersion else {
            throw WorkspaceError.invalidRegistry(
                "checkout visibility schema \(schemaVersion) is unsupported"
            )
        }
        guard let rawEntries = document["hidden_checkouts"] as? [[String: Any]] else {
            throw WorkspaceError.invalidRegistry("hidden_checkouts must contain JSON objects")
        }
        guard rawEntries.count <= Self.entryLimit else {
            throw WorkspaceError.invalidRegistry("hidden checkout limit exceeded")
        }

        var keys = Set<CheckoutKey>()
        for raw in rawEntries {
            guard let projectID = raw["project_id"] as? String,
                  let path = raw["path"] as? String else {
                throw WorkspaceError.invalidRegistry("hidden checkout is missing project_id or path")
            }
            try WorkspaceValidation.identifier(projectID, label: "project id")
            try Self.validateStoredPath(path)
            guard keys.insert(CheckoutKey(projectID: projectID, path: path)).inserted else {
                throw WorkspaceError.invalidRegistry("hidden checkout entries must be unique")
            }
        }
        return VisibilityState(document: document, rawEntries: rawEntries, keys: keys)
    }

    private static func canonicalPath(for url: URL) throws -> String {
        guard url.isFileURL else {
            throw WorkspaceError.invalidRegistry("hidden checkout path must be a file URL")
        }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        try validateStoredPath(path)
        return path
    }

    private static func validateStoredPath(_ path: String) throws {
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard path.hasPrefix("/"), path == standardized,
              !path.contains("\u{0}"), path.utf8.count <= pathByteLimit else {
            throw WorkspaceError.invalidRegistry("hidden checkout path must be canonical and bounded")
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }
}

/// Stable identity for a session hidden from the Manager workspace outline.
/// Session IDs are only task-scoped, so every visibility mutation uses the
/// complete project/task/session tuple.
public struct WorkspaceClosedSessionKey: Hashable, Sendable {
    public let projectID: String
    public let taskID: String
    public let sessionID: String

    public init(projectID: String, taskID: String, sessionID: String) {
        self.projectID = projectID
        self.taskID = taskID
        self.sessionID = sessionID
    }
}

public protocol WorkspaceSessionVisibilityPersisting: Sendable {
    func closedSessionKeys() async throws -> Set<WorkspaceClosedSessionKey>
    func close(_ key: WorkspaceClosedSessionKey) async throws
    func restore(_ key: WorkspaceClosedSessionKey) async throws
}

/// Manager-owned presentation metadata. Closing a session never rewrites the
/// shared task/session lifecycle document, so older CLIs and Manager versions
/// cannot discard or reinterpret the user's durable history.
public actor WorkspaceSessionVisibilityStore: WorkspaceSessionVisibilityPersisting {
    private struct VisibilityState {
        var document: [String: Any]
        var rawEntries: [[String: Any]]
        var keys: Set<WorkspaceClosedSessionKey>
    }

    private static let schemaVersion = 1
    private static let fileByteLimit = 4 * 1_024 * 1_024
    private static let entryLimit = 20_000

    private let stateURL: URL
    private let lockURL: URL
    private let now: @Sendable () -> Date

    public init(
        home: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let standardizedHome = home.standardizedFileURL
        self.stateURL = standardizedHome
            .appendingPathComponent("manager", isDirectory: true)
            .appendingPathComponent("session-visibility.json")
        self.lockURL = standardizedHome.appendingPathComponent("locks/session-visibility.lock")
        self.now = now
    }

    public func closedSessionKeys() async throws -> Set<WorkspaceClosedSessionKey> {
        try readState().keys
    }

    public func close(_ key: WorkspaceClosedSessionKey) async throws {
        try Self.validate(key)
        try WorkspaceDisk.withExclusiveLock(at: lockURL) {
            var state = try readState()
            guard !state.keys.contains(key) else { return }
            guard state.rawEntries.count < Self.entryLimit else {
                throw WorkspaceError.invalidRegistry("closed session limit exceeded")
            }
            state.rawEntries.append([
                "project_id": key.projectID,
                "task_id": key.taskID,
                "session_id": key.sessionID,
                "closed_at": Self.dateString(now()),
            ])
            state.document["schema_version"] = Self.schemaVersion
            state.document["closed_sessions"] = state.rawEntries
            try WorkspaceDisk.writeJSONObject(state.document, to: stateURL)
        }
    }

    public func restore(_ key: WorkspaceClosedSessionKey) async throws {
        try Self.validate(key)
        try WorkspaceDisk.withExclusiveLock(at: lockURL) {
            var state = try readState()
            guard state.keys.contains(key) else { return }
            state.rawEntries.removeAll { raw in
                raw["project_id"] as? String == key.projectID
                    && raw["task_id"] as? String == key.taskID
                    && raw["session_id"] as? String == key.sessionID
            }
            state.document["schema_version"] = Self.schemaVersion
            state.document["closed_sessions"] = state.rawEntries
            try WorkspaceDisk.writeJSONObject(state.document, to: stateURL)
        }
    }

    private func readState() throws -> VisibilityState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return VisibilityState(
                document: [
                    "schema_version": Self.schemaVersion,
                    "closed_sessions": [[String: Any]](),
                ],
                rawEntries: [],
                keys: []
            )
        }
        let data = try WorkspaceDisk.readData(
            at: stateURL,
            byteLimit: Self.fileByteLimit,
            label: "session visibility"
        )
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WorkspaceError.invalidRegistry("session visibility JSON is malformed")
        }
        guard let document = value as? [String: Any] else {
            throw WorkspaceError.invalidRegistry("session visibility root must be an object")
        }
        guard let rawSchemaVersion = document["schema_version"],
              let schemaVersion = Self.integer(rawSchemaVersion) else {
            throw WorkspaceError.invalidRegistry(
                "session visibility schema_version must be an integer"
            )
        }
        guard schemaVersion == Self.schemaVersion else {
            throw WorkspaceError.invalidRegistry(
                "session visibility schema \(schemaVersion) is unsupported"
            )
        }
        guard let rawEntries = document["closed_sessions"] as? [[String: Any]] else {
            throw WorkspaceError.invalidRegistry("closed_sessions must contain JSON objects")
        }
        guard rawEntries.count <= Self.entryLimit else {
            throw WorkspaceError.invalidRegistry("closed session limit exceeded")
        }

        var keys = Set<WorkspaceClosedSessionKey>()
        for raw in rawEntries {
            guard let projectID = raw["project_id"] as? String,
                  let taskID = raw["task_id"] as? String,
                  let sessionID = raw["session_id"] as? String,
                  let closedAt = raw["closed_at"] as? String,
                  Self.parseDate(closedAt) != nil else {
                throw WorkspaceError.invalidRegistry(
                    "closed session is missing a valid identity or timestamp"
                )
            }
            let key = WorkspaceClosedSessionKey(
                projectID: projectID,
                taskID: taskID,
                sessionID: sessionID
            )
            try Self.validate(key)
            guard keys.insert(key).inserted else {
                throw WorkspaceError.invalidRegistry("closed session entries must be unique")
            }
        }
        return VisibilityState(document: document, rawEntries: rawEntries, keys: keys)
    }

    private static func validate(_ key: WorkspaceClosedSessionKey) throws {
        try WorkspaceValidation.identifier(key.projectID, label: "project id")
        try WorkspaceValidation.identifier(key.taskID, label: "task id")
        try WorkspaceValidation.identifier(key.sessionID, label: "session id")
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseDate(_ value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

public protocol WorkspaceTaskPersisting: Sendable {
    func task(id: String) async throws -> WorkspaceTask?
    func tasks(projectID: String?, limit: Int) async throws -> WorkspaceTaskList
    func createTask(
        projectID: String,
        checkout: WorkspaceCheckoutReference,
        title: String
    ) async throws -> WorkspaceTask
    func createSession(
        taskID: String,
        name: String?,
        provider: WorkspaceProvider,
        model: String
    ) async throws -> WorkspaceSession
    func updateSessionStatus(
        taskID: String,
        sessionID: String,
        status: WorkspaceSessionStatus,
        nativeSessionID: String?
    ) async throws -> WorkspaceSession
    func updateTaskStatus(taskID: String, status: WorkspaceTaskStatus) async throws -> WorkspaceTask
}

public actor WorkspaceTaskStore: WorkspaceTaskPersisting {
    private struct TaskDocument: Codable {
        let schemaVersion: Int
        let task: WorkspaceTask

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case task
        }
    }

    private static let schemaVersion = 1
    private static let stateByteLimit = 1 * 1_024 * 1_024
    private static let scanLimit = 2_000

    private let home: URL
    private let tasksRoot: URL
    private let idGenerator: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(
        home: URL,
        idGenerator: @escaping @Sendable () -> String = {
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home.standardizedFileURL
        self.tasksRoot = home.standardizedFileURL.appendingPathComponent("tasks", isDirectory: true)
        self.idGenerator = idGenerator
        self.now = now
    }

    public func task(id: String) async throws -> WorkspaceTask? {
        try WorkspaceValidation.identifier(id, label: "task id")
        let stateURL = taskStateURL(id: id)
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try readTask(at: stateURL)
    }

    public func tasks(
        projectID: String? = nil,
        limit: Int = 200
    ) async throws -> WorkspaceTaskList {
        if let projectID { try WorkspaceValidation.identifier(projectID, label: "project id") }
        let requestedLimit = min(max(limit, 1), 1_000)
        guard FileManager.default.fileExists(atPath: tasksRoot.path) else {
            return WorkspaceTaskList(tasks: [], isTruncated: false)
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: tasksRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw WorkspaceError.persistence("cannot enumerate task metadata")
        }

        var truncated = entries.count > Self.scanLimit
        var values: [WorkspaceTask] = []
        for directory in entries.prefix(Self.scanLimit) {
            let stateURL = directory.appendingPathComponent("state.json")
            guard FileManager.default.fileExists(atPath: stateURL.path) else { continue }
            let value = try readTask(at: stateURL)
            if projectID == nil || value.projectID == projectID {
                values.append(value)
            }
        }
        values.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
        if values.count > requestedLimit { truncated = true }
        return WorkspaceTaskList(
            tasks: Array(values.prefix(requestedLimit)),
            isTruncated: truncated
        )
    }

    public func createTask(
        projectID: String,
        checkout: WorkspaceCheckoutReference,
        title: String
    ) async throws -> WorkspaceTask {
        let taskID = idGenerator()
        let date = now()
        let value = try WorkspaceTask(
            id: taskID,
            projectID: projectID,
            checkout: checkout,
            title: title,
            createdAt: date,
            updatedAt: date
        )
        return try withTaskLock {
            let stateURL = taskStateURL(id: taskID)
            guard !FileManager.default.fileExists(atPath: stateURL.path) else {
                throw WorkspaceError.persistence("generated task id already exists")
            }
            try writeTask(value)
            return value
        }
    }

    public func createSession(
        taskID: String,
        name: String? = nil,
        provider: WorkspaceProvider,
        model: String
    ) async throws -> WorkspaceSession {
        try WorkspaceValidation.identifier(taskID, label: "task id")
        let session = try WorkspaceSession(
            id: idGenerator(),
            name: name,
            provider: provider,
            model: model,
            createdAt: now()
        )
        return try withTaskLock {
            guard let task = try readTaskIfPresent(id: taskID) else {
                throw WorkspaceError.taskNotFound(taskID)
            }
            let updated = try task.adding(session: session, at: now())
            try writeTask(updated)
            return session
        }
    }

    public func updateSessionStatus(
        taskID: String,
        sessionID: String,
        status: WorkspaceSessionStatus,
        nativeSessionID: String? = nil
    ) async throws -> WorkspaceSession {
        try WorkspaceValidation.identifier(taskID, label: "task id")
        try WorkspaceValidation.identifier(sessionID, label: "session id")
        return try withTaskLock {
            guard let task = try readTaskIfPresent(id: taskID) else {
                throw WorkspaceError.taskNotFound(taskID)
            }
            guard let session = task.sessions.first(where: { $0.id == sessionID }) else {
                throw WorkspaceError.sessionNotFound(sessionID)
            }
            if status == .active,
               task.sessions.contains(where: { $0.id != sessionID && !$0.status.isTerminal }) {
                throw WorkspaceError.openSessionExists(taskID)
            }
            let date = now()
            let updatedSession = try session.updating(
                status: status,
                nativeSessionID: nativeSessionID ?? session.nativeSessionID,
                at: date
            )
            let updatedTask = try task.replacing(session: updatedSession, at: date)
            try writeTask(updatedTask)
            return updatedSession
        }
    }

    public func updateTaskStatus(
        taskID: String,
        status: WorkspaceTaskStatus
    ) async throws -> WorkspaceTask {
        try WorkspaceValidation.identifier(taskID, label: "task id")
        return try withTaskLock {
            guard let task = try readTaskIfPresent(id: taskID) else {
                throw WorkspaceError.taskNotFound(taskID)
            }
            let updated = try task.updating(status: status, at: now())
            try writeTask(updated)
            return updated
        }
    }

    private func withTaskLock<T>(_ body: () throws -> T) throws -> T {
        try WorkspaceDisk.withExclusiveLock(
            at: home.appendingPathComponent("locks/workspace-tasks.lock"),
            body
        )
    }

    private func readTaskIfPresent(id: String) throws -> WorkspaceTask? {
        let stateURL = taskStateURL(id: id)
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try readTask(at: stateURL)
    }

    private func readTask(at stateURL: URL) throws -> WorkspaceTask {
        let data = try WorkspaceDisk.readData(
            at: stateURL,
            byteLimit: Self.stateByteLimit,
            label: "task state"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: TaskDocument
        do {
            document = try decoder.decode(TaskDocument.self, from: data)
        } catch {
            throw WorkspaceError.persistence("task state is malformed")
        }
        guard document.schemaVersion == Self.schemaVersion else {
            throw WorkspaceError.persistence("unsupported task state schema")
        }

        // Codable reconstruction does not call the public validating initializers.
        // Rebuild each value so persisted identity and active-session invariants are checked.
        let sessions = try document.task.sessions.map { session in
            try WorkspaceSession(
                id: session.id,
                name: session.name,
                provider: session.provider,
                model: session.model,
                status: session.status,
                nativeSessionID: session.nativeSessionID,
                createdAt: session.createdAt,
                startedAt: session.startedAt,
                endedAt: session.endedAt
            )
        }
        return try WorkspaceTask(
            id: document.task.id,
            projectID: document.task.projectID,
            checkout: document.task.checkout,
            title: document.task.title,
            status: document.task.status,
            sessions: sessions,
            createdAt: document.task.createdAt,
            updatedAt: document.task.updatedAt
        )
    }

    private func writeTask(_ task: WorkspaceTask) throws {
        let stateURL = taskStateURL(id: task.id)
        try WorkspaceDisk.ensurePrivateDirectory(stateURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(TaskDocument(schemaVersion: Self.schemaVersion, task: task))
        } catch {
            throw WorkspaceError.persistence("cannot encode task state")
        }
        guard data.count <= Self.stateByteLimit else {
            throw WorkspaceError.persistence("task state exceeds the 1 MiB metadata limit")
        }
        try WorkspaceDisk.writeData(data, to: stateURL)
    }

    private func taskStateURL(id: String) -> URL {
        tasksRoot
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("state.json")
    }
}

private enum WorkspaceDisk {
    static func ensurePrivateDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw WorkspaceError.persistence("cannot create private metadata directory")
        }
    }

    static func readData(at url: URL, byteLimit: Int, label: String) throws -> Data {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber, size.intValue > byteLimit {
                throw WorkspaceError.persistence("\(label) exceeds its \(byteLimit)-byte limit")
            }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.persistence("cannot read \(label)")
        }
    }

    static func writeJSONObject(_ value: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw WorkspaceError.persistence("project registry contains invalid JSON values")
        }
        var data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
        } catch {
            throw WorkspaceError.persistence("cannot encode project registry")
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw WorkspaceError.persistence("project registry exceeds the 4 MiB limit")
        }
        try writeData(data, to: url)
    }

    static func writeData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: [])
            guard chmod(temporary.path, 0o600) == 0 else {
                throw WorkspaceError.persistence("cannot protect temporary metadata")
            }
            let descriptor = Darwin.open(temporary.path, O_RDONLY)
            if descriptor >= 0 {
                _ = fsync(descriptor)
                _ = close(descriptor)
            }
            let result = temporary.path.withCString { source in
                url.path.withCString { destination in Darwin.rename(source, destination) }
            }
            guard result == 0 else {
                throw WorkspaceError.persistence("cannot atomically replace metadata")
            }
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                _ = close(directoryDescriptor)
            }
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.persistence("cannot write metadata")
        }
    }

    static func withExclusiveLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw WorkspaceError.persistence("cannot open metadata lock")
        }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw WorkspaceError.persistence("cannot acquire metadata lock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}
