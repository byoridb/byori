import Darwin
import Foundation

public struct VerificationScope: Codable, Equatable, Hashable, Sendable {
    public let projectID: String
    public let checkoutID: String
    public let taskID: String
    public let root: URL
    public init(projectID: String, checkoutID: String, taskID: String, root: URL) {
        self.projectID = projectID; self.checkoutID = checkoutID; self.taskID = taskID
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }
    func validate() throws {
        for id in [projectID, checkoutID, taskID] { try WorkspaceValidation.identifier(id, label: "verification identity") }
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else {
            throw VerificationError.invalid("검증할 작업 트리 경로가 올바르지 않습니다.")
        }
    }
}

public struct VerificationCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var timeout: TimeInterval
    public var required: Bool
    public init(id: String = UUID().uuidString, name: String, executable: String,
                arguments: [String] = [], timeout: TimeInterval = 300, required: Bool = true) {
        self.id = id; self.name = name; self.executable = executable
        self.arguments = arguments; self.timeout = timeout; self.required = required
    }
    public var displayCommand: String {
        ([executable] + arguments).map { value in
            if value.isEmpty { return "''" }
            if value.range(of: #"^[A-Za-z0-9_./:=,@%+\-]+$"#, options: .regularExpression) != nil { return value }
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
    public func validate() throws {
        try WorkspaceValidation.identifier(id, label: "verification command id")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 240,
              !executable.isEmpty, executable.utf8.count <= 4_096, arguments.count <= 64,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 8_192,
              ([name, executable] + arguments).allSatisfy({ !$0.contains("\0") }),
              !name.contains("\n"), !executable.contains("\n"), !executable.contains("\r"),
              timeout.isFinite, (1...1_800).contains(timeout) else {
            throw VerificationError.invalid("검증 이름·실행 파일·인수와 제한 시간(1~1800초)을 확인해 주세요.")
        }
    }
}

public struct VerificationProfile: Codable, Equatable, Sendable {
    public var commands: [VerificationCommand]
    public init(commands: [VerificationCommand] = []) { self.commands = commands }
    public func validate() throws {
        guard commands.count <= 12, Set(commands.map(\.id)).count == commands.count else {
            throw VerificationError.invalid("검증 명령은 서로 다른 ID로 최대 12개까지 등록할 수 있습니다.")
        }
        try commands.forEach { try $0.validate() }
    }
}

public enum VerificationOutcome: String, Codable, Equatable, Sendable {
    case running, passed, failed, timedOut, cancelled, interrupted
}

public enum VerificationState: String, Equatable, Sendable {
    case notConfigured, notRun, running, passed, failed, timedOut, cancelled, interrupted, stale, unverified
    public var title: String {
        switch self {
        case .notConfigured: return "검증 미설정"
        case .notRun: return "미실행"
        case .running: return "실행 중"
        case .passed: return "통과"
        case .failed: return "실패"
        case .timedOut: return "시간 초과"
        case .cancelled: return "취소됨"
        case .interrupted: return "중단됨"
        case .stale: return "코드·설정 변경"
        case .unverified: return "코드 상태 미확인"
        }
    }
}

public struct VerificationAssessment: Equatable, Sendable {
    public let state: VerificationState
    public let detail: String
    public let receiptID: String?
    public var canComplete: Bool { state == .passed }
    public init(state: VerificationState, detail: String, receiptID: String? = nil) {
        self.state = state; self.detail = detail; self.receiptID = receiptID
    }
}

public struct VerificationReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let scope: VerificationScope
    public let command: VerificationCommand
    public let resolvedExecutable: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var outcome: VerificationOutcome
    public var exitCode: Int32?
    public var before: VerificationFingerprint?
    public var after: VerificationFingerprint?
    public var output: String
    public var outputTruncated: Bool
    public init(id: String = UUID().uuidString, scope: VerificationScope, command: VerificationCommand,
                resolvedExecutable: String, startedAt: Date = Date(), finishedAt: Date? = nil,
                outcome: VerificationOutcome = .running, exitCode: Int32? = nil,
                before: VerificationFingerprint? = nil, after: VerificationFingerprint? = nil,
                output: String = "", outputTruncated: Bool = false) {
        self.id = id; self.scope = scope; self.command = command; self.resolvedExecutable = resolvedExecutable
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.outcome = outcome; self.exitCode = exitCode
        self.before = before; self.after = after; self.output = output; self.outputTruncated = outputTruncated
    }
    public func assessment(current: VerificationFingerprint?, command currentCommand: VerificationCommand?) -> VerificationAssessment {
        func result(_ state: VerificationState, _ detail: String) -> VerificationAssessment {
            .init(state: state, detail: detail, receiptID: id)
        }
        switch outcome {
        case .running: return result(.running, "명령 실행과 코드 상태 확인이 진행 중입니다.")
        case .cancelled: return result(.cancelled, "사용자가 검증을 취소했습니다.")
        case .timedOut: return result(.timedOut, "설정한 제한 시간 안에 명령이 끝나지 않았습니다.")
        case .interrupted: return result(.interrupted, "앱이 종료되었거나 실행 결과를 저장하지 못했습니다. 다시 실행해 주세요.")
        case .failed: return result(.failed, "명령이 성공적으로 끝나지 않았습니다. 실행 기록을 확인해 주세요.")
        case .passed: break
        }
        guard exitCode == 0, finishedAt != nil else { return result(.unverified, "명령의 성공 종료 기록을 확인할 수 없습니다.") }
        guard currentCommand == command else { return result(.stale, "검증 명령 설정이 달라졌거나 삭제되었습니다.") }
        guard let before, let after, let current,
              before.complete, after.complete, current.complete else {
            return result(.unverified, "명령은 성공했지만 코드 상태를 완전히 비교하지 못했습니다.")
        }
        guard before.matches(after) else { return result(.stale, "검증 실행 중 코드가 변경되었습니다. 현재 코드에서 다시 실행해 주세요.") }
        guard after.matches(current) else { return result(.stale, "검증 이후 커밋 또는 파일 내용이 변경되었습니다.") }
        return result(.passed, "등록한 명령이 성공했고 검증 전후·현재 코드 상태가 같습니다. 환경과 무시된 파일은 확인 범위 밖입니다.")
    }
}

public struct VerificationSnapshot: Sendable {
    public let scope: VerificationScope
    public let profile: VerificationProfile
    public let receipts: [VerificationReceipt]
    public let current: VerificationFingerprint?
    public init(scope: VerificationScope, profile: VerificationProfile, receipts: [VerificationReceipt], current: VerificationFingerprint?) {
        self.scope = scope; self.profile = profile; self.receipts = receipts; self.current = current
    }
    public func assessment(for command: VerificationCommand) -> VerificationAssessment {
        guard let receipt = receipts.first(where: { $0.command.id == command.id }) else {
            return .init(state: .notRun, detail: "이 작업에서 아직 실행하지 않은 검증입니다.")
        }
        return receipt.assessment(current: current, command: command)
    }
    public var requiredAssessment: VerificationAssessment {
        let required = profile.commands.filter(\.required)
        guard !required.isEmpty else { return .init(state: .notConfigured, detail: "완료 판단에 사용할 필수 검증을 설정해 주세요.") }
        let values = required.map { assessment(for: $0) }
        // Never let one successful command hide a missing, changed or failed check.
        for state in [VerificationState.running, .failed, .timedOut, .cancelled, .interrupted, .notRun, .stale, .unverified] {
            if let value = values.first(where: { $0.state == state }) { return value }
        }
        return .init(state: .passed, detail: "필수 검증 \(required.count)개가 현재 코드에서 통과했습니다. 검증 범위 밖의 요구사항과 검토 결과도 확인해 주세요.")
    }
}

public enum VerificationError: LocalizedError, Sendable {
    case invalid(String), persistence, missingTask, scopeMismatch, running, invalidTicket, missingCommand
    public var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        case .persistence: return "검증 기록을 안전하게 읽거나 저장할 수 없습니다. 로컬 작업 저장소의 권한과 기록을 확인해 주세요."
        case .missingTask: return "작업을 찾을 수 없습니다. 보관되거나 삭제된 작업에는 검증 기록을 쓰지 않습니다."
        case .scopeMismatch: return "작업의 프로젝트 또는 작업 트리가 요청과 다릅니다. 작업을 다시 선택해 주세요."
        case .running: return "이 작업 트리의 검증이 이미 실행 중입니다. 완료하거나 취소한 뒤 다시 실행해 주세요."
        case .invalidTicket: return "검증 실행 요청이 만료되었거나 이미 사용되었습니다."
        case .missingCommand: return "검증 명령이 변경되었거나 없습니다. 설정을 다시 불러와 주세요."
        }
    }
}

public struct VerificationRunTicket: Sendable {
    public let id: String
    public let scope: VerificationScope
    fileprivate let token: UUID
}

/// User-triggered verification only. Preparing reserves one checkout before the
/// app releases its workspace mutation gate; execution never holds that gate.
public actor TaskVerificationService {
    private let paths: ManagerPaths
    private let runner: any CommandRunning
    private let fingerprinter: any VerificationFingerprinting
    private let store: VerificationStore
    private let now: @Sendable () -> Date
    private var active: [String: (ticket: VerificationRunTicket, receipt: VerificationReceipt)] = [:]
    private var executing: Set<String> = []
    public init(home: URL, paths: ManagerPaths, runner: any CommandRunning = ProcessCommandRunner(),
                fingerprinter: (any VerificationFingerprinting)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths; self.runner = runner
        self.fingerprinter = fingerprinter ?? GitVerificationFingerprinter(paths: paths, runner: runner)
        self.store = VerificationStore(home: home); self.now = now
    }
    public func profile(projectID: String) throws -> VerificationProfile { try store.profile(projectID: projectID) }
    public func saveProfile(projectID: String, commands: [VerificationCommand]) throws {
        guard !active.values.contains(where: { $0.ticket.scope.projectID == projectID }) else { throw VerificationError.running }
        try store.saveProfile(projectID: projectID, profile: VerificationProfile(commands: commands))
    }
    public func isRunning(taskID: String? = nil, root: URL? = nil) -> Bool {
        active.values.contains { value in
            (taskID == nil || value.ticket.scope.taskID == taskID)
                && (root == nil || value.ticket.scope.root == root?.standardizedFileURL.resolvingSymlinksInPath())
        }
    }
    public func snapshot(scope: VerificationScope) async throws -> VerificationSnapshot {
        try scope.validate()
        _ = try store.history(scope: scope, activeIDs: Set(active.keys))
        let current = await fingerprinter.capture(root: scope.root)
        // A command may have finished while fingerprinting. Return the latest
        // persisted receipts, not the pre-await running state.
        let latest = try store.history(scope: scope, activeIDs: Set(active.keys))
        let profile = try store.profile(projectID: scope.projectID)
        return VerificationSnapshot(scope: scope, profile: profile,
                                    receipts: latest, current: current)
    }
    public func prepareRun(scope: VerificationScope, commandID: String) throws -> VerificationRunTicket {
        try scope.validate()
        guard !active.values.contains(where: {
            $0.ticket.scope.root == scope.root ||
                ($0.ticket.scope.projectID == scope.projectID && $0.ticket.scope.checkoutID == scope.checkoutID)
        }) else { throw VerificationError.running }
        let profile = try store.profile(projectID: scope.projectID)
        guard let command = profile.commands.first(where: { $0.id == commandID }) else { throw VerificationError.missingCommand }
        try command.validate()
        let executable: URL?
        if command.executable.hasPrefix("/") { executable = URL(fileURLWithPath: command.executable) }
        else if command.executable.contains("/") { executable = scope.root.appendingPathComponent(command.executable) }
        else { executable = paths.executable(named: command.executable) }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw VerificationError.invalid("실행 파일을 찾을 수 없습니다: \(command.executable)")
        }
        let receipt = VerificationReceipt(scope: scope, command: command,
            resolvedExecutable: executable.standardizedFileURL.resolvingSymlinksInPath().path, startedAt: now())
        let ticket = VerificationRunTicket(id: receipt.id, scope: scope, token: UUID())
        try store.save(receipt, activeIDs: Set(active.keys))
        active[ticket.id] = (ticket, receipt)
        return ticket
    }
    public func executeRun(_ ticket: VerificationRunTicket) async throws -> VerificationReceipt {
        guard let reserved = active[ticket.id], reserved.ticket.token == ticket.token,
              !executing.contains(ticket.id) else { throw VerificationError.invalidTicket }
        executing.insert(ticket.id)
        defer { executing.remove(ticket.id); active.removeValue(forKey: ticket.id) }
        var receipt = reserved.receipt
        do {
            try Task.checkCancellation()
            receipt.before = await fingerprinter.capture(root: ticket.scope.root)
            try Task.checkCancellation()
            try store.save(receipt, activeIDs: Set(active.keys))
            var removals = Set(ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("GIT_") })
            removals.formUnion(["BYORIDB_PASSWORD", "BYORIDB_ROOT_PASSWORD", "CLAUDE_PROJECT_DIR", "BYORI_TASK_ID"])
            let result = await runner.run(CommandSpec(
                executable: receipt.resolvedExecutable, arguments: receipt.command.arguments,
                environment: ["PATH": paths.processPath, "CLAUDE_PROJECT_DIR": ticket.scope.root.path, "BYORI_TASK_ID": ticket.scope.taskID],
                workingDirectory: ticket.scope.root.path, timeout: receipt.command.timeout,
                preserveOutputWhitespace: true, environmentRemovals: removals,
                terminateProcessGroupOnExit: true
            ))
            receipt.exitCode = result.exitCode
            let outputBytes = Data(result.output.utf8)
            var tail = outputBytes.suffix(64 * 1_024)
            // Do not expand a cut UTF-8 scalar into replacement bytes beyond
            // the storage limit. Discard only the incomplete leading scalar.
            while let first = tail.first, first & 0xc0 == 0x80 { tail.removeFirst() }
            receipt.output = String(decoding: tail, as: UTF8.self)
            receipt.outputTruncated = result.outputTruncated || outputBytes.count > 64 * 1_024
            if result.cancelled || Task.isCancelled { receipt.outcome = .cancelled }
            else if result.timedOut { receipt.outcome = .timedOut }
            else { receipt.outcome = result.succeeded ? .passed : .failed }
            if !Task.isCancelled { receipt.after = await fingerprinter.capture(root: ticket.scope.root) }
            if Task.isCancelled { receipt.outcome = .cancelled }
        } catch {
            receipt.outcome = error is CancellationError || Task.isCancelled ? .cancelled : .failed
            receipt.output = error is CancellationError ? "" : error.localizedDescription
        }
        receipt.finishedAt = now()
        // Persistence failure is never presented as a durable successful result.
        try store.save(receipt, activeIDs: Set(active.keys))
        return receipt
    }
}

/// Shared private task sidecars. Uses the same flock as WorkspaceTaskStore so
/// late writes cannot recreate a task directory after it has been archived.
public struct TaskArtifactStore: Sendable {
    private let disk: VerificationDisk
    public init(home: URL) { disk = VerificationDisk(home: home) }
    public func read(scope: VerificationScope, name: String, byteLimit: Int) throws -> Data? {
        try disk.withTask(scope) { directory in try disk.read(name, in: directory, limit: byteLimit) }
    }
    public func write(scope: VerificationScope, name: String, data: Data, byteLimit: Int) throws {
        guard data.count <= byteLimit else { throw VerificationError.persistence }
        try disk.withTask(scope) { directory in try disk.write(data, name: name, in: directory) }
    }
}

private struct VerificationStore: Sendable {
    private struct ProfileDocument: Codable { let version: Int; let profile: VerificationProfile }
    private struct HistoryDocument: Codable { let version: Int; var receipts: [VerificationReceipt] }
    private let disk: VerificationDisk
    init(home: URL) { disk = VerificationDisk(home: home) }
    func profile(projectID: String) throws -> VerificationProfile {
        try WorkspaceValidation.identifier(projectID, label: "project id")
        return try disk.withLock {
            guard let directory = try disk.directory(["verification-profiles"], create: false) else { return VerificationProfile() }
            defer { close(directory) }
            guard let data = try disk.read(projectID + ".json", in: directory, limit: 1_024 * 1_024) else { return VerificationProfile() }
            let document: ProfileDocument = try decode(data)
            guard document.version == 1 else { throw VerificationError.persistence }
            try document.profile.validate()
            return document.profile
        }
    }
    func saveProfile(projectID: String, profile: VerificationProfile) throws {
        try WorkspaceValidation.identifier(projectID, label: "project id")
        try profile.validate()
        let data = try encode(ProfileDocument(version: 1, profile: profile))
        guard data.count <= 1_024 * 1_024 else { throw VerificationError.persistence }
        try disk.withLock {
            guard let directory = try disk.directory(["verification-profiles"], create: true) else { throw VerificationError.persistence }
            defer { close(directory) }
            try disk.write(data, name: projectID + ".json", in: directory)
        }
    }
    func history(scope: VerificationScope, activeIDs: Set<String>) throws -> [VerificationReceipt] {
        try disk.withTask(scope) { directory in
            let original = try load(scope: scope, directory: directory)
            let refreshed = interrupted(original, activeIDs: activeIDs)
            if refreshed != original { try write(refreshed, directory: directory) }
            return refreshed
        }
    }
    func save(_ receipt: VerificationReceipt, activeIDs: Set<String>) throws {
        try disk.withTask(receipt.scope) { directory in
            var values = interrupted(try load(scope: receipt.scope, directory: directory), activeIDs: activeIDs)
            values.removeAll { $0.id == receipt.id }
            values.insert(receipt, at: 0)
            try write(Array(values.prefix(30)), directory: directory)
        }
    }
    private func interrupted(_ receipts: [VerificationReceipt], activeIDs: Set<String>) -> [VerificationReceipt] {
        receipts.map { original in
            var value = original
            if value.outcome == .running && !activeIDs.contains(value.id) {
                value.outcome = .interrupted
            }
            return value
        }
    }
    private func load(scope: VerificationScope, directory: Int32) throws -> [VerificationReceipt] {
        guard let data = try disk.read("verification.json", in: directory, limit: 16 * 1_024 * 1_024) else { return [] }
        let document: HistoryDocument = try decode(data)
        guard document.version == 1, document.receipts.count <= 30,
              Set(document.receipts.map(\.id)).count == document.receipts.count else { throw VerificationError.persistence }
        for value in document.receipts {
            try value.scope.validate(); try value.command.validate()
            guard value.scope.projectID == scope.projectID, value.scope.taskID == scope.taskID,
                  value.scope.checkoutID == scope.checkoutID,
                  value.output.utf8.count <= 64 * 1_024,
                  value.outcome != .passed || (value.exitCode == 0 && value.finishedAt != nil) else {
                throw VerificationError.persistence
            }
        }
        return document.receipts
    }
    private func write(_ values: [VerificationReceipt], directory: Int32) throws {
        let data = try encode(HistoryDocument(version: 1, receipts: values))
        guard data.count <= 16 * 1_024 * 1_024 else { throw VerificationError.persistence }
        try disk.write(data, name: "verification.json", in: directory)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) } catch { throw VerificationError.persistence }
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw VerificationError.persistence }
    }
}

private struct VerificationDisk: Sendable {
    private struct TaskDocument: Decodable {
        let schemaVersion: Int
        let task: WorkspaceTask
        enum CodingKeys: String, CodingKey { case task; case schemaVersion = "schema_version" }
    }
    let home: URL
    init(home: URL) { self.home = home.standardizedFileURL.resolvingSymlinksInPath() }
    private func safeName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else {
            throw VerificationError.persistence
        }
    }
    func directory(_ names: [String], create: Bool) throws -> Int32? {
        if create && !FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var fd = Darwin.open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT && !create { return nil }; throw VerificationError.persistence }
        do {
            for name in names {
                try safeName(name)
                if create {
                    let code = mkdirat(fd, name, 0o700)
                    if code != 0 && errno != EEXIST { throw VerificationError.persistence }
                }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    if errno == ENOENT && !create { close(fd); return nil }
                    throw VerificationError.persistence
                }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    func withLock<T>(_ body: () throws -> T) throws -> T {
        guard let locks = try directory(["locks"], create: true) else { throw VerificationError.persistence }
        defer { close(locks) }
        let lock = openat(locks, "workspace-tasks.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw VerificationError.persistence }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG else { throw VerificationError.persistence }
        guard flock(lock, LOCK_EX) == 0 else { throw VerificationError.persistence }
        defer { _ = flock(lock, LOCK_UN) }
        return try body()
    }
    func withTask<T>(_ scope: VerificationScope, _ body: (Int32) throws -> T) throws -> T {
        try scope.validate()
        return try withLock {
            guard let directory = try directory(["tasks", scope.taskID], create: false) else { throw VerificationError.missingTask }
            defer { close(directory) }
            guard let data = try read("state.json", in: directory, limit: 1_024 * 1_024) else { throw VerificationError.missingTask }
            let document: TaskDocument
            do {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                document = try decoder.decode(TaskDocument.self, from: data)
            } catch { throw VerificationError.persistence }
            guard document.schemaVersion == 1 else { throw VerificationError.persistence }
            guard document.task.id == scope.taskID, document.task.projectID == scope.projectID,
                  document.task.checkout.id == scope.checkoutID else { throw VerificationError.scopeMismatch }
            return try body(directory)
        }
    }
    func read(_ name: String, in directory: Int32, limit: Int) throws -> Data? {
        try safeName(name)
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 { if errno == ENOENT { return nil }; throw VerificationError.persistence }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw VerificationError.persistence }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw VerificationError.persistence }
            guard data.count + count <= limit else { throw VerificationError.persistence }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    func write(_ data: Data, name: String, in directory: Int32) throws {
        try safeName(name)
        // Refuse symlink destinations even though atomic rename would replace
        // the link itself. A corrupted store should be visible, not repaired.
        var existing = stat()
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG else { throw VerificationError.persistence }
        } else if errno != ENOENT { throw VerificationError.persistence }
        let temporary = ".verification-\(UUID().uuidString).tmp"
        let file = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw VerificationError.persistence }
        defer { close(file); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 { if errno == EINTR { continue }; throw VerificationError.persistence }
                guard count > 0 else { throw VerificationError.persistence }
                written += count
            }
        }
        guard fsync(file) == 0, renameat(directory, temporary, directory, name) == 0,
              fsync(directory) == 0 else { throw VerificationError.persistence }
    }
}
