import Foundation

public enum TaskWorkflowPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case bugFix, feature, codeReview
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bugFix: return "버그 수정"
        case .feature: return "기능 추가"
        case .codeReview: return "코드 리뷰"
        }
    }
    public var summary: String {
        switch self {
        case .bugFix: return "재현 → 원인 확인 → 수정 → 회귀 검증 → 인계"
        case .feature: return "범위 합의 → 설계 → 구현 → 검증 → 리뷰·인계"
        case .codeReview: return "범위 확인 → 변경 검토 → 검증 → 결과 전달"
        }
    }
    public func makePlan(goal: String) -> TaskWorkflowPlan {
        let definitions: [(String, String, String)]
        let criteria: String
        switch self {
        case .bugFix:
            definitions = [
                ("reproduce", "증상 재현", "기대 동작과 실제 동작, 재현 조건을 적고 재현 가능한 사례를 확보합니다."),
                ("cause", "원인 확인", "관련 코드와 기존 결정·사건 기록을 확인하고 원인과 근거를 연결합니다."),
                ("fix", "수정", "합의한 범위에서 원인을 수정하고 주변 동작에 미치는 영향을 확인합니다."),
                ("verify", "회귀 검증", "재현 사례와 관련 테스트를 실제로 실행합니다. 필요한 검증 명령을 검증 탭에 등록합니다."),
                ("handoff", "결과 인계", "수정 원인·변경 내용·실행한 검증·남은 제약을 다음 담당자에게 전달합니다.")
            ]
            criteria = "재현 사례에서 문제가 해결됨\n관련 회귀 검증을 실행함\n남은 제약과 확인하지 못한 범위를 기록함"
        case .feature:
            definitions = [
                ("scope", "범위 합의", "사용자가 얻을 결과와 완료 조건, 이번 작업에 포함할 범위를 정리합니다."),
                ("design", "설계", "현재 구조·기존 결정·변경 영향을 확인하고 구현 접근을 정합니다."),
                ("implement", "구현", "작은 단위로 구현하고 기존 동작과의 호환성을 유지합니다."),
                ("verify", "검증", "완료 조건에 맞는 빌드·테스트·검사를 선택해 실제로 실행합니다."),
                ("handoff", "리뷰·인계", "변경과 검증 근거를 검토하고 후속 작업과 알려진 제약을 남깁니다.")
            ]
            criteria = "합의한 사용자 동작을 구현함\n필요한 빌드·테스트를 실행함\n검토 결과와 남은 제약을 기록함"
        case .codeReview:
            definitions = [
                ("scope", "검토 범위 확인", "대상 변경과 기대 동작, 비교 기준을 확인합니다."),
                ("inspect", "변경 검토", "정확성·회귀·오류 처리·권한·데이터 흐름을 실제 코드와 근거로 검토합니다."),
                ("verify", "검증", "관련 검증을 실행하고 미실행 항목과 확인할 수 없는 조건을 구분합니다."),
                ("report", "결과 전달", "중요도·위치·재현 근거와 함께 발견 사항을 전달합니다. 발견하지 못한 경우에도 검토 범위를 명시합니다.")
            ]
            criteria = "검토 범위와 기준을 명시함\n발견 사항에 위치와 근거를 연결함\n검증 결과와 미확인 범위를 구분함"
        }
        return TaskWorkflowPlan(preset: self, goal: goal, acceptanceCriteria: criteria,
                                steps: definitions.map { TaskWorkflowStep(id: $0.0, title: $0.1, instructions: $0.2) })
    }
}

public struct TaskWorkflowStep: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let instructions: String
    public var completed: Bool
    public init(id: String, title: String, instructions: String, completed: Bool = false) {
        self.id = id; self.title = title; self.instructions = instructions; self.completed = completed
    }
}

public struct TaskWorkflowPlan: Codable, Equatable, Sendable {
    public let preset: TaskWorkflowPreset
    public var goal: String
    public var acceptanceCriteria: String
    public var notes: String
    public var steps: [TaskWorkflowStep]
    public init(preset: TaskWorkflowPreset, goal: String, acceptanceCriteria: String = "", notes: String = "", steps: [TaskWorkflowStep]) {
        self.preset = preset; self.goal = goal; self.acceptanceCriteria = acceptanceCriteria
        self.notes = notes; self.steps = steps
    }
    public var handoffText: String {
        let progress = steps.map { "[\($0.completed ? "x" : " ")] \($0.title)\n\($0.instructions)" }.joined(separator: "\n\n")
        return "작업 절차: \(preset.title)\n\n목표\n\(goal)\n\n완료 조건\n\(acceptanceCriteria)\n\n단계 확인 (사용자 표시)\n\(progress)\n\n인계 메모\n\(notes)\n\n단계 체크는 실제 검증 실행 결과와 별도입니다. 현재 코드와 검증 이력을 확인하고 이어가세요."
    }
    public func validate() throws {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              goal.utf8.count <= 8_000, acceptanceCriteria.utf8.count <= 16_000,
              notes.utf8.count <= 32_000, !steps.isEmpty, steps.count <= 12,
              Set(steps.map(\.id)).count == steps.count,
              [goal, acceptanceCriteria, notes].allSatisfy({ !$0.contains("\0") }),
              steps.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 80 && !$0.title.isEmpty
                  && $0.title.utf8.count <= 256 && $0.instructions.utf8.count <= 4_000
                  && !($0.id + $0.title + $0.instructions).contains("\0") }) else {
            throw WorkspaceError.persistence("작업 절차 입력이 비어 있거나 허용 크기를 초과했습니다.")
        }
    }
}

/// Workflow is task-owned operational metadata. The task's existing archive
/// operation moves this sidecar together with state.json and session metadata.
public struct TaskWorkflowStore: Sendable {
    private let artifacts: TaskArtifactStore
    public init(home: URL) { artifacts = TaskArtifactStore(home: home) }
    private struct Document: Codable {
        var version: Int = 1
        let plan: TaskWorkflowPlan
    }
    public func load(scope: VerificationScope) throws -> TaskWorkflowPlan? {
        guard let data = try artifacts.read(scope: scope, name: "workflow.json", byteLimit: 128 * 1024) else { return nil }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw WorkspaceError.persistence("저장한 작업 절차를 읽을 수 없습니다.") }
        guard document.version == 1 else { throw WorkspaceError.persistence("지원하지 않는 작업 절차 형식입니다.") }
        try document.plan.validate()
        return document.plan
    }
    public func save(_ plan: TaskWorkflowPlan, scope: VerificationScope) throws {
        try plan.validate()
        let data = try JSONEncoder().encode(Document(plan: plan))
        try artifacts.write(scope: scope, name: "workflow.json", data: data, byteLimit: 128 * 1024)
    }
}
