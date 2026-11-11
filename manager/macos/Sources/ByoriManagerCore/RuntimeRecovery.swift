import Foundation

/// Diagnoses are intentionally separate from actions: an authentication failure
/// or a foreign listener is not evidence that restarting our service will help.
public enum RuntimeDiagnosis: String, Codable, Sendable, Equatable {
    case healthy, notInstalled, missingConfiguration, stopped, unresponsive
    case foreignListener, authenticationFailed, diskLow, inspectionFailed, queryFailed

    public var title: String {
        switch self {
        case .healthy: return "정상 · 인증과 그래프 조회 확인"
        case .notInstalled: return "런타임 설치 필요"
        case .missingConfiguration: return "연결 또는 서비스 설정 확인 필요"
        case .stopped: return "설치된 서비스가 중지됨"
        case .unresponsive: return "관리 서비스가 응답하지 않음"
        case .foreignListener: return "다른 프로세스가 포트를 사용 중"
        case .authenticationFailed: return "연결 비밀번호 확인 필요"
        case .diskLow: return "저장 공간 부족"
        case .inspectionFailed: return "서비스 상태를 확인할 수 없음"
        case .queryFailed: return "인증 후 그래프 조회 실패"
        }
    }

    public var detail: String {
        switch self {
        case .healthy: return "Byori가 관리하는 프로세스에 연결해 인증과 읽기 전용 조회를 확인했습니다."
        case .notInstalled: return "ByoriDB 설치·업데이트에서 런타임을 설치해 주세요."
        case .missingConfiguration: return "연결 정보, 실행 스크립트, launchd 설정을 확인해 주세요. 자동으로 다시 설치하지 않습니다."
        case .stopped: return "등록된 ByoriDB 서비스를 시작한 뒤 연결 상태를 다시 확인할 수 있습니다."
        case .unresponsive: return "Byori가 관리하는 서비스를 한 번 재시작한 뒤 연결 상태를 다시 확인할 수 있습니다."
        case .foreignListener: return "포트 소유자가 Byori의 launchd 프로세스와 다릅니다. 해당 프로세스를 확인해 주세요."
        case .authenticationFailed: return "저장 데이터와 연결 정보의 비밀번호가 일치하는지 확인해 주세요. 비밀번호를 초기화하지 않습니다."
        case .diskLow: return "ByoriDB 저장 볼륨에 최소 256MB의 여유 공간을 확보한 뒤 다시 확인해 주세요."
        case .inspectionFailed: return "launchd, 포트 소유권 또는 디스크 상태를 확인하지 못했습니다. 로그와 로컬 권한을 확인해 주세요."
        case .queryFailed: return "서비스는 응답하지만 그래프를 조회하지 못했습니다. 엔진 버전과 서버 로그를 확인해 주세요."
        }
    }

    public var action: RuntimeRecoveryAction? {
        switch self {
        case .stopped: return .start
        case .unresponsive: return .restart
        default: return nil
        }
    }
}

public enum RuntimeRecoveryAction: String, Codable, Sendable {
    case start, restart
    public var title: String { self == .start ? "서비스 시작" : "서비스 재시작" }
}

public struct RuntimeRecoveryAttempt: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case pending, verified, failed, cancelled
        public var title: String {
            switch self {
            case .pending: return "완료 여부 미확인"
            case .verified: return "복구 후 검증 성공"
            case .failed: return "복구 후 검증 실패"
            case .cancelled: return "취소됨 · 상태 다시 확인 필요"
            }
        }
    }
    public let id: UUID
    public let startedAt: Date
    public let action: RuntimeRecoveryAction
    public let automatic: Bool
    public var outcome: Outcome
    public var diagnosis: RuntimeDiagnosis
}

public struct RuntimeRecoveryState: Codable, Sendable, Equatable {
    public var attempts: [RuntimeRecoveryAttempt] = []
    public var userStopped = false
    public init() {}
}

public protocol RuntimeRecoveryStoring: Sendable {
    func load() throws -> RuntimeRecoveryState
    func save(_ state: RuntimeRecoveryState) throws
}

/// Independent of ByoriDB so a failed database cannot erase the retry budget.
/// Atomic replacement prevents a terminated app from leaving a half-written file.
public struct RuntimeRecoveryFileStore: RuntimeRecoveryStoring {
    public let url: URL
    public init(url: URL) { self.url = url }

    private func checkPath() throws {
        let fm = FileManager.default
        for path in [url.deletingLastPathComponent().path, url.path] {
            if let attributes = try? fm.attributesOfItem(atPath: path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw RuntimeRecoveryError.persistenceUnavailable
            }
        }
    }

    public func load() throws -> RuntimeRecoveryState {
        try checkPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return RuntimeRecoveryState() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 256 * 1_024 else {
            throw RuntimeRecoveryError.persistenceUnavailable
        }
        return try JSONDecoder().decode(RuntimeRecoveryState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: RuntimeRecoveryState) throws {
        try checkPath()
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct RuntimeRecoveryReport: Sendable {
    public let diagnosis: RuntimeDiagnosis
    public let attemptsUsed: Int
    public let attemptLimit: Int
    public let nextAttemptAt: Date?
    public let lastAttempt: RuntimeRecoveryAttempt?
    public let userStopped: Bool
    public let isRunning: Bool
    public let persistenceAvailable: Bool
    public let checkedAt: Date

    public var canRecover: Bool {
        diagnosis.action != nil && nextAttemptAt == nil && !isRunning && persistenceAvailable
    }
    public var canRecoverAutomatically: Bool { canRecover && !userStopped }
}

public enum RuntimeRecoveryError: LocalizedError, Sendable, Equatable {
    case persistenceUnavailable, alreadyRunning, userStopped, retryDeferred(Date)
    case refused(RuntimeDiagnosis), verificationFailed(RuntimeDiagnosis)
    public var errorDescription: String? {
        switch self {
        case .persistenceUnavailable:
            return "복구 기록을 안전하게 읽거나 저장할 수 없어 복구를 중단했습니다. ~/.byori-manager의 권한과 복구 기록을 확인해 주세요."
        case .alreadyRunning: return "이미 진단·복구가 진행 중입니다."
        case .userStopped: return "사용자가 서비스를 중지해 자동 복구를 실행하지 않았습니다."
        case let .retryDeferred(date):
            return "반복 복구를 제한했습니다. \(date.formatted(date: .omitted, time: .standard)) 이후 다시 확인해 주세요."
        case let .refused(diagnosis): return diagnosis.detail
        case let .verificationFailed(diagnosis): return "복구 후 확인: \(diagnosis.title). \(diagnosis.detail)"
        }
    }
}

/// One observation/action/verification cycle per call. There is no background
/// retry loop. An attempt is durably reserved *before* touching the service, so
/// cancellation, process termination and relaunch cannot reset its budget.
public actor RuntimeRecoveryController {
    private let store: any RuntimeRecoveryStoring
    private let now: @Sendable () -> Date
    private let attemptLimit: Int
    private let window: TimeInterval
    private let cooldown: TimeInterval
    private var isRunning = false

    public init(
        store: any RuntimeRecoveryStoring,
        now: @escaping @Sendable () -> Date = { Date() },
        attemptLimit: Int = 3,
        window: TimeInterval = 600,
        cooldown: TimeInterval = 60
    ) {
        self.store = store
        self.now = now
        self.attemptLimit = max(1, attemptLimit)
        self.window = max(1, window)
        self.cooldown = max(1, cooldown)
    }

    public func status(diagnosis: RuntimeDiagnosis) -> RuntimeRecoveryReport {
        do { return report(diagnosis, state: try store.load()) }
        catch { return report(diagnosis, state: RuntimeRecoveryState(), persistenceAvailable: false) }
    }

    public func setUserStopped(_ stopped: Bool) throws {
        do {
            var state = try store.load()
            state.userStopped = stopped
            try store.save(state)
        } catch { throw RuntimeRecoveryError.persistenceUnavailable }
    }

    public func recover(
        automatic: Bool,
        observe: @Sendable () async -> RuntimeDiagnosis,
        repair: @Sendable (RuntimeRecoveryAction) async throws -> Void
    ) async throws -> RuntimeRecoveryReport {
        guard !isRunning else { throw RuntimeRecoveryError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }
        try Task.checkCancellation()
        let diagnosis = await observe()
        var state: RuntimeRecoveryState
        do { state = try store.load() }
        catch { throw RuntimeRecoveryError.persistenceUnavailable }
        if automatic && state.userStopped { throw RuntimeRecoveryError.userStopped }
        if diagnosis == .healthy { return report(diagnosis, state: state, running: false) }
        guard let action = diagnosis.action else { throw RuntimeRecoveryError.refused(diagnosis) }
        if let next = nextAttempt(state, at: now()) { throw RuntimeRecoveryError.retryDeferred(next) }
        try Task.checkCancellation()

        // Retain bounded recent history, including the latest result across windows.
        state.attempts = Array(state.attempts.suffix(19))
        let id = UUID()
        state.attempts.append(RuntimeRecoveryAttempt(
            id: id, startedAt: now(), action: action, automatic: automatic,
            outcome: .pending, diagnosis: diagnosis
        ))
        if !automatic { state.userStopped = false }
        do { try store.save(state) }
        catch { throw RuntimeRecoveryError.persistenceUnavailable }

        do {
            try Task.checkCancellation()
            try await repair(action)
            try Task.checkCancellation()
            let verified = await observe()
            try Task.checkCancellation()
            guard verified == .healthy else { throw RuntimeRecoveryError.verificationFailed(verified) }
            try finish(id: id, outcome: .verified, diagnosis: verified)
            return report(verified, state: try store.load(), running: false)
        } catch {
            let finalDiagnosis: RuntimeDiagnosis
            if case let RuntimeRecoveryError.verificationFailed(value) = error { finalDiagnosis = value }
            else if case let RuntimeRecoveryError.refused(value) = error { finalDiagnosis = value }
            else { finalDiagnosis = diagnosis }
            try finish(id: id, outcome: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
                       diagnosis: finalDiagnosis)
            throw error
        }
    }

    private func finish(id: UUID, outcome: RuntimeRecoveryAttempt.Outcome, diagnosis: RuntimeDiagnosis) throws {
        do {
            var state = try store.load()
            guard let index = state.attempts.firstIndex(where: { $0.id == id }) else {
                throw RuntimeRecoveryError.persistenceUnavailable
            }
            state.attempts[index].outcome = outcome
            state.attempts[index].diagnosis = diagnosis
            try store.save(state)
        } catch { throw RuntimeRecoveryError.persistenceUnavailable }
    }

    private func nextAttempt(_ state: RuntimeRecoveryState, at date: Date) -> Date? {
        // Future timestamps stay in the window if the clock moves backwards.
        let active = state.attempts.filter { date.timeIntervalSince($0.startedAt) < window }
        var next = state.attempts.last?.startedAt.addingTimeInterval(cooldown)
        if active.count >= attemptLimit, let oldest = active.map(\.startedAt).min() {
            next = max(next ?? oldest, oldest.addingTimeInterval(window))
        }
        return next.flatMap { $0 > date ? $0 : nil }
    }

    private func report(
        _ diagnosis: RuntimeDiagnosis, state: RuntimeRecoveryState,
        persistenceAvailable: Bool = true, running: Bool? = nil
    ) -> RuntimeRecoveryReport {
        let date = now()
        return RuntimeRecoveryReport(
            diagnosis: diagnosis,
            attemptsUsed: state.attempts.filter { date.timeIntervalSince($0.startedAt) < window }.count,
            attemptLimit: attemptLimit, nextAttemptAt: nextAttempt(state, at: date),
            lastAttempt: state.attempts.last, userStopped: state.userStopped,
            isRunning: running ?? isRunning, persistenceAvailable: persistenceAvailable, checkedAt: date
        )
    }
}
