import CryptoKit
import Darwin
import Foundation

/// The local inputs observed for a verification command, not proof of behavior.
/// Incomplete observations never compare equal, even if both have no digest.
public struct VerificationFingerprint: Codable, Equatable, Sendable {
    public let root: String
    public let revision: String?
    public let digest: String?
    public let complete: Bool
    public let reason: String?
    public let checkedAt: Date
    public let files: Int
    public let bytes: Int
    public let coverage: String

    public static let defaultCoverage = "Git tracked and unignored regular files, staged index and HEAD. Ignored files, external dependencies and environment state are excluded. Symlinks and submodules remain unverified."

    public init(
        root: String, revision: String? = nil, digest: String? = nil,
        complete: Bool, reason: String? = nil, checkedAt: Date = Date(),
        files: Int = 0, bytes: Int = 0, coverage: String = Self.defaultCoverage
    ) {
        self.root = root; self.revision = revision; self.digest = digest
        self.complete = complete; self.reason = reason; self.checkedAt = checkedAt
        self.files = files; self.bytes = bytes; self.coverage = coverage
    }

    public func matches(_ other: VerificationFingerprint) -> Bool {
        complete && other.complete && digest != nil && revision != nil
            && root == other.root && revision == other.revision && digest == other.digest
            && coverage == other.coverage
    }
}

public protocol VerificationFingerprinting: Sendable {
    func capture(root: URL) async -> VerificationFingerprint
}

public struct VerificationFingerprintLimits: Sendable {
    public let maxFiles: Int
    public let maxBytes: Int
    public let maxFileBytes: Int
    public let maxOutputBytes: Int
    public let maxDuration: TimeInterval

    public init(
        maxFiles: Int = 20_000, maxBytes: Int = 128 * 1_024 * 1_024,
        maxFileBytes: Int = 16 * 1_024 * 1_024, maxOutputBytes: Int = 256 * 1_024,
        maxDuration: TimeInterval = 10
    ) {
        self.maxFiles = max(0, maxFiles)
        self.maxBytes = max(0, maxBytes)
        self.maxFileBytes = max(0, maxFileBytes)
        self.maxOutputBytes = max(0, maxOutputBytes)
        self.maxDuration = maxDuration.isFinite ? max(0, maxDuration) : 0
    }
}

/// Bounded, read-only observation. No project hooks, filters or diff drivers run.
/// Files are opened relative to a pinned root descriptor without following links.
public struct GitVerificationFingerprinter: VerificationFingerprinting {
    private let runner: any CommandRunning
    private let limits: VerificationFingerprintLimits
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let processPath: String

    public init(
        paths: ManagerPaths = .applicationDefault(),
        runner: any CommandRunning = ProcessCommandRunner(),
        limits: VerificationFingerprintLimits = VerificationFingerprintLimits(),
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.runner = runner; self.limits = limits; self.now = now
        self.uptime = uptime; self.processPath = paths.processPath
    }

    public func capture(root inputRoot: URL) async -> VerificationFingerprint {
        var root = inputRoot
        let deadline = uptime() + limits.maxDuration
        var progress = Progress()
        var revision: String?
        do {
            try checkBudget(deadline)
            guard inputRoot.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else {
                throw Failure("not_git_root")
            }
            // Foundation preserves some macOS aliases (/var versus
            // /private/var). Git returns the physical POSIX working directory.
            guard let physical = root.path.withCString({ Darwin.realpath($0, nil) }) else {
                throw Failure("not_git_root")
            }
            defer { free(physical) }
            guard let path = String(validatingUTF8: physical) else { throw Failure("invalid_path_encoding") }
            root = URL(fileURLWithPath: path, isDirectory: true)
            let rootFD = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard rootFD >= 0 else { throw Failure("not_git_root") }
            defer { Darwin.close(rootFD) }
            let rootIdentity = try signature(rootFD)
            try await requireRoot(root, deadline: deadline)
            let before = try await inventory(root, deadline: deadline)
            revision = before.revision
            guard before.entries.count <= limits.maxFiles else { throw Failure("file_limit") }

            var hasher = SHA256()
            feed(Data("byori-verification-inputs-v1".utf8), into: &hasher)
            feed(Data(root.path.utf8), into: &hasher)
            feed(Data(before.revision.utf8), into: &hasher)
            feed(before.indexBytes, into: &hasher)
            var observations: [Observation] = []
            for entry in before.entries {
                try checkBudget(deadline)
                let observation = try read(entry, rootFD: rootFD, progress: &progress, deadline: deadline)
                observations.append(observation)
                feed(entry.pathBytes, into: &hasher)
                feed(Data(observation.contentIdentity.utf8), into: &hasher)
                progress.files += 1
                await Task.yield()
            }

            let after = try await inventory(root, deadline: deadline)
            guard before.revision == after.revision, before.indexBytes == after.indexBytes,
                  before.untrackedPaths == after.untrackedPaths else { throw Failure("changed_during_scan") }
            try await requireRoot(root, deadline: deadline)
            let finalRootFD = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard finalRootFD >= 0 else { throw Failure("changed_during_scan") }
            defer { Darwin.close(finalRootFD) }
            let finalRoot = try signature(finalRootFD)
            guard rootIdentity.device == finalRoot.device, rootIdentity.inode == finalRoot.inode else {
                throw Failure("changed_during_scan")
            }
            // Inventory equality alone misses edits to an already-listed file.
            // Finish all subprocess awaits before this pass: a Git root query
            // must not open a fresh window after validating the file contents.
            for observation in observations {
                try checkBudget(deadline)
                let descriptor = try open(observation.entry, rootFD: rootFD, deadline: deadline)
                let current: Signature?
                if let descriptor {
                    defer { Darwin.close(descriptor) }
                    current = try signature(descriptor)
                    guard current?.isRegular == true else { throw Failure("unsupported_file") }
                } else { current = nil }
                guard current == observation.signature else { throw Failure("changed_during_scan") }
            }
            try checkBudget(deadline)
            return VerificationFingerprint(
                root: root.path, revision: revision,
                digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                complete: true, checkedAt: now(), files: progress.files, bytes: progress.bytes
            )
        } catch {
            return VerificationFingerprint(
                root: root.path, revision: revision, complete: false,
                reason: Task.isCancelled ? "cancelled" : (error as? Failure)?.reason ?? "unreadable_file",
                checkedAt: now(), files: progress.files, bytes: progress.bytes
            )
        }
    }

    private struct Failure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
    private struct Progress { var files = 0; var bytes = 0 }
    private struct Entry { let path: String; let pathBytes: Data; let tracked: Bool }
    private struct Inventory {
        let revision: String
        let indexBytes: Data
        let untrackedPaths: [Data]
        let entries: [Entry]
    }
    private struct Observation {
        let entry: Entry
        let signature: Signature?
        let contentIdentity: String
    }
    private struct Signature: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        var isRegular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    }

    private func checkBudget(_ deadline: TimeInterval) throws {
        if Task.isCancelled { throw Failure("cancelled") }
        if uptime() >= deadline { throw Failure("time_limit") }
    }

    private func git(_ arguments: [String], root: URL, deadline: TimeInterval) async throws -> CommandResult {
        try checkBudget(deadline)
        let removals = Set(ProcessInfo.processInfo.environment.keys.filter {
            $0.hasPrefix("GIT_") || $0 == "BYORIDB_ROOT_PASSWORD" || $0 == "BYORIDB_PASSWORD"
        }).union(["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "BYORIDB_PASSWORD", "BYORIDB_ROOT_PASSWORD"])
        let result = await runner.run(CommandSpec(
            executable: "/usr/bin/git",
            arguments: ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", root.path] + arguments,
            environment: ["PATH": processPath, "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"],
            workingDirectory: root.path, timeout: min(5, max(0.001, deadline - uptime())),
            preserveOutputWhitespace: true, environmentRemovals: removals
        ))
        try checkBudget(deadline)
        if result.cancelled { throw Failure("cancelled") }
        if result.timedOut { throw Failure("time_limit") }
        if result.outputTruncated || result.output.utf8.count > limits.maxOutputBytes { throw Failure("inventory_limit") }
        if !result.outputEncodingValid { throw Failure("invalid_path_encoding") }
        return result
    }

    private func requireRoot(_ root: URL, deadline: TimeInterval) async throws {
        let result = try await git(["rev-parse", "--show-toplevel"], root: root, deadline: deadline)
        guard result.succeeded, result.output == root.path + "\n" else { throw Failure("not_git_root") }
    }

    private func inventory(_ root: URL, deadline: TimeInterval) async throws -> Inventory {
        let revisionResult = try await git(["rev-parse", "--verify", "HEAD"], root: root, deadline: deadline)
        let revision = revisionResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard revisionResult.succeeded,
              revision.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil else {
            throw Failure("unverified_head")
        }
        let index = try await git(["ls-files", "--stage", "--cached", "-z"], root: root, deadline: deadline)
        let untracked = try await git(["ls-files", "--others", "--exclude-standard", "-z"], root: root, deadline: deadline)
        guard index.succeeded, untracked.succeeded else { throw Failure("inventory_failed") }
        var entries: [Entry] = []
        var seen = Set<Data>()
        for record in try records(index.output) {
            guard let tab = record.firstIndex(of: "\t") else { throw Failure("inventory_failed") }
            let header = record[..<tab].split(separator: " ", omittingEmptySubsequences: false)
            guard header.count == 3, header[2] == "0" else { throw Failure("unmerged_index") }
            guard ["100644", "100755", "120000", "160000"].contains(String(header[0])),
                  String(header[1]).range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil else {
                throw Failure("inventory_failed")
            }
            if header[0] == "160000" { throw Failure("submodule") }
            if header[0] == "120000" { throw Failure("symlink") }
            let path = String(record[record.index(after: tab)...])
            try validatePath(path)
            let bytes = Data(path.utf8)
            guard seen.insert(bytes).inserted else { throw Failure("inventory_failed") }
            entries.append(Entry(path: path, pathBytes: bytes, tracked: true))
            if entries.count > limits.maxFiles { throw Failure("file_limit") }
        }
        var untrackedPaths: [Data] = []
        for path in try records(untracked.output) {
            try validatePath(path)
            let bytes = Data(path.utf8)
            guard seen.insert(bytes).inserted else { throw Failure("inventory_failed") }
            entries.append(Entry(path: path, pathBytes: bytes, tracked: false))
            untrackedPaths.append(bytes)
            if entries.count > limits.maxFiles { throw Failure("file_limit") }
        }
        entries.sort { $0.pathBytes.lexicographicallyPrecedes($1.pathBytes) }
        untrackedPaths.sort { $0.lexicographicallyPrecedes($1) }
        return Inventory(revision: revision, indexBytes: Data(index.output.utf8), untrackedPaths: untrackedPaths, entries: entries)
    }

    private func records(_ output: String) throws -> [String] {
        guard !output.isEmpty else { return [] }
        guard output.hasSuffix("\0") else { throw Failure("inventory_failed") }
        let pieces = output.split(separator: "\0", omittingEmptySubsequences: false)
        guard pieces.dropLast().allSatisfy({ !$0.isEmpty }) else { throw Failure("inventory_failed") }
        return pieces.dropLast().map(String.init)
    }

    private func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw Failure("unsafe_path")
        }
    }

    /// A tracked missing path is a valid deletion. An untracked path disappearing
    /// after enumeration indicates a race. Symlinks and special files fail closed.
    private func open(_ entry: Entry, rootFD: Int32, deadline: TimeInterval) throws -> Int32? {
        let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        var directory = Darwin.dup(rootFD)
        guard directory >= 0 else { throw Failure("unreadable_file") }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            try checkBudget(deadline)
            let next = String(component).withCString { Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
            if next < 0 {
                let code = errno
                if code == ENOENT && entry.tracked { return nil }
                throw Failure(code == ELOOP || code == ENOTDIR ? "symlink_or_unsupported_path" : "changed_or_unreadable_file")
            }
            Darwin.close(directory)
            directory = next
        }
        try checkBudget(deadline)
        let descriptor = String(components.last!).withCString { Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        if descriptor < 0 {
            let code = errno
            if code == ENOENT && entry.tracked { return nil }
            throw Failure(code == ELOOP ? "symlink" : "changed_or_unreadable_file")
        }
        return descriptor
    }

    private func signature(_ descriptor: Int32) throws -> Signature {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw Failure("unreadable_file") }
        return Signature(
            device: info.st_dev, inode: info.st_ino, mode: info.st_mode, size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec
        )
    }

    private func read(_ entry: Entry, rootFD: Int32, progress: inout Progress, deadline: TimeInterval) throws -> Observation {
        guard let descriptor = try open(entry, rootFD: rootFD, deadline: deadline) else {
            return Observation(entry: entry, signature: nil, contentIdentity: "missing")
        }
        defer { Darwin.close(descriptor) }
        let before = try signature(descriptor)
        guard before.isRegular, before.size >= 0 else { throw Failure("unsupported_file") }
        guard before.size <= limits.maxFileBytes else { throw Failure("file_byte_limit") }
        guard before.size <= limits.maxBytes - progress.bytes else { throw Failure("byte_limit") }
        var fileHash = SHA256()
        var remaining = Int(before.size)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while remaining > 0 {
            try checkBudget(deadline)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, min(remaining, $0.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure("changed_or_unreadable_file") }
            progress.bytes += count
            remaining -= count
            fileHash.update(data: Data(buffer.prefix(count)))
        }
        guard try signature(descriptor) == before else { throw Failure("changed_during_scan") }
        let digest = fileHash.finalize().map { String(format: "%02x", $0) }.joined()
        return Observation(entry: entry, signature: before, contentIdentity: "regular:\(before.mode & 0o7777):\(before.size):\(digest)")
    }

    private func feed(_ value: Data, into hasher: inout SHA256) {
        hasher.update(data: Data("\(value.count):".utf8))
        hasher.update(data: value)
    }
}
