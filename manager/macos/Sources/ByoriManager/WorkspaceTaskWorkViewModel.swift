import ByoriManagerCore
import Foundation

@MainActor
protocol WorkspaceTaskWorkProviding {
    func loadWorkflow() async throws -> TaskWorkflowPlan?
    func saveWorkflow(_ plan: TaskWorkflowPlan) async throws
    func loadVerification() async throws -> VerificationSnapshot
    func saveVerificationCommands(_ commands: [VerificationCommand]) async throws
    func runVerification(commandID: String) async throws -> VerificationReceipt
}

struct WorkspaceVerificationCommandDraft: Equatable, Identifiable {
    var id: String
    var name: String
    var executable: String
    var argumentsText: String
    var timeoutText: String
    var required: Bool
    private let originalArguments: [String]
    private let originalArgumentsText: String

    init(_ command: VerificationCommand) {
        id = command.id; name = command.name; executable = command.executable
        argumentsText = command.arguments.joined(separator: "\n")
        originalArguments = command.arguments; originalArgumentsText = argumentsText
        timeoutText = String(command.timeout); required = command.required
    }

    func command() throws -> VerificationCommand {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExecutable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedExecutable.isEmpty else {
            throw WorkspaceTaskWorkError.invalidCommand("명령 이름과 실행 파일을 입력하세요.")
        }
        guard let timeout = TimeInterval(timeoutText), timeout.isFinite, timeout >= 1, timeout <= 1800 else {
            throw WorkspaceTaskWorkError.invalidCommand("제한 시간은 1~1,800초로 입력하세요.")
        }
        return VerificationCommand(id: id, name: trimmedName, executable: trimmedExecutable,
            arguments: argumentsText == originalArgumentsText ? originalArguments
                : argumentsText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
            timeout: timeout, required: required)
    }
}

enum WorkspaceTaskWorkError: LocalizedError {
    case invalidCommand(String)
    var errorDescription: String? { switch self { case let .invalidCommand(message): return message } }
}

enum WorkspaceVerificationStarter: String, CaseIterable, Identifiable {
    case python = "Python", swift = "Swift", node = "Node.js", rust = "Rust", custom = "직접 입력"
    var id: String { rawValue }
    var command: VerificationCommand {
        switch self {
        case .python: return .init(name: "Python 테스트", executable: "python3", arguments: ["-m", "pytest"])
        case .swift: return .init(name: "Swift 테스트", executable: "swift", arguments: ["test"])
        case .node: return .init(name: "Node.js 테스트", executable: "npm", arguments: ["test"])
        case .rust: return .init(name: "Rust 테스트", executable: "cargo", arguments: ["test"])
        case .custom: return .init(name: "", executable: "")
        }
    }
}

/// A presentation and its provider stay bound to the captured task and checkout.
/// Workflow checkboxes are user notes; only persisted execution receipts attest to tests.
@MainActor
final class WorkspaceTaskWorkViewModel: ObservableObject {
    let scope: WorkspaceTaskWorkScope
    @Published var plan: TaskWorkflowPlan
    @Published var selectedPreset: TaskWorkflowPreset = .feature
    @Published var commandDrafts: [WorkspaceVerificationCommandDraft] = []
    @Published var selectedReceiptID: String?
    @Published private(set) var snapshot: VerificationSnapshot?
    @Published private(set) var hasLoaded = false
    @Published private(set) var hasLoadedWorkflow = false
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSaving = false
    @Published private(set) var runningCommandID: String?
    @Published private(set) var isCancelling = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var workflowError: String?
    @Published private(set) var verificationError: String?
    @Published private(set) var notice: String?

    private let provider: any WorkspaceTaskWorkProviding
    private var savedPlan: TaskWorkflowPlan?
    private var initialPlan: TaskWorkflowPlan
    private var savedCommandDrafts: [WorkspaceVerificationCommandDraft] = []
    private var generation = UUID()
    private var refreshGeneration = UUID()
    private var executionTask: Task<Void, Never>?

    init(scope: WorkspaceTaskWorkScope, provider: any WorkspaceTaskWorkProviding) {
        self.scope = scope; self.provider = provider
        let initial = TaskWorkflowPreset.feature.makePlan(goal: scope.taskTitle)
        plan = initial; initialPlan = initial
    }

    var isRunning: Bool { runningCommandID != nil }
    var isBusy: Bool { isLoading || isSaving || isRefreshing || isRunning }
    var isWorkflowDirty: Bool { plan != (savedPlan ?? initialPlan) || savedPlan == nil }
    var hasWorkflowToReplace: Bool { savedPlan != nil || plan != initialPlan }
    var isProfileDirty: Bool { commandDrafts != savedCommandDrafts }
    var canRun: Bool { snapshot != nil && !isProfileDirty && !isBusy }
    var selectedReceipt: VerificationReceipt? {
        snapshot?.receipts.first(where: { $0.id == selectedReceiptID }) ?? snapshot?.receipts.first
    }
    var handoffText: String {
        let verification: String
        if isProfileDirty {
            verification = "검증 명령에 저장하지 않은 변경이 있습니다. 명령을 저장하고 현재 코드에서 검증하세요."
        } else if isRunning {
            verification = "검증 실행이 아직 끝나지 않았습니다. 완료된 실행 기록을 확인하세요."
        } else if !isRefreshing, verificationError == nil, let assessment = snapshot?.requiredAssessment {
            verification = "\(assessment.state.title): \(assessment.detail)"
        } else {
            verification = "현재 검증 상태를 확인하지 못했습니다. 검증 화면에서 다시 확인하세요."
        }
        let checkedAt = snapshot?.current?.checkedAt.formatted() ?? "미확인"
        return "작업: \(scope.title)\n작업 트리: \(scope.root.path)\n\n\(plan.handoffText)\n\n실행 검증 (마지막 확인)\n확인 시각: \(checkedAt)\n\(verification)\n확인 이후의 코드·설정 변경은 이 인계문에 반영되지 않습니다. 작업을 이어갈 때 상태를 다시 확인하세요."
    }

    func load() async {
        guard !hasLoaded, !isLoading else { return }
        let token = generation
        isLoading = true; errorMessage = nil
        await readWorkflow()
        guard token == generation, !Task.isCancelled else { return }
        await refreshVerification(replaceDrafts: true)
        guard token == generation, !Task.isCancelled else { return }
        isLoading = false; hasLoaded = true
    }

    func applyPreset() {
        guard !isBusy, hasLoadedWorkflow else { return }
        plan = selectedPreset.makePlan(goal: plan.goal)
        notice = "절차 초안을 적용했습니다. 내용을 검토한 뒤 저장하세요."
    }

    func saveWorkflow() async {
        guard !isBusy, hasLoadedWorkflow else { return }
        let token = generation, draft = plan
        isSaving = true; errorMessage = nil; notice = nil
        defer { if token == generation { isSaving = false } }
        do {
            try await provider.saveWorkflow(draft)
            guard token == generation, !Task.isCancelled else { return }
            savedPlan = draft; notice = "작업 절차를 저장했습니다."
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func addCommand(_ starter: WorkspaceVerificationStarter) {
        guard !isBusy, snapshot != nil, commandDrafts.count < 12 else { return }
        commandDrafts.append(.init(starter.command))
    }

    func removeCommand(id: String) {
        guard !isBusy, snapshot != nil else { return }
        commandDrafts.removeAll { $0.id == id }
    }

    func saveCommands() async {
        guard !isBusy, snapshot != nil, commandDrafts.count <= 12 else { return }
        let token = generation
        isSaving = true; errorMessage = nil; notice = nil
        defer { if token == generation { isSaving = false } }
        do {
            let commands = try commandDrafts.map { try $0.command() }
            try await provider.saveVerificationCommands(commands)
            guard token == generation, !Task.isCancelled else { return }
            savedCommandDrafts = commands.map(WorkspaceVerificationCommandDraft.init)
            commandDrafts = savedCommandDrafts
            notice = "이 프로젝트의 검증 명령을 저장했습니다. 실행 버튼으로 직접 시작하세요."
            await refreshVerification()
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refreshVerification(replaceDrafts: Bool = false) async {
        guard !isRunning else { return }
        let token = generation, refreshToken = UUID()
        refreshGeneration = refreshToken; isRefreshing = true; verificationError = nil
        defer { if token == generation, refreshToken == refreshGeneration { isRefreshing = false } }
        do {
            let loaded = try await provider.loadVerification()
            guard token == generation, refreshToken == refreshGeneration, !Task.isCancelled else { return }
            applySnapshot(loaded, replaceDrafts: replaceDrafts)
        } catch {
            guard token == generation, refreshToken == refreshGeneration, !Task.isCancelled else { return }
            snapshot = nil
            verificationError = "현재 검증 상태를 확인하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func run(commandID: String) {
        guard canRun, snapshot?.profile.commands.contains(where: { $0.id == commandID }) == true else { return }
        let token = generation
        runningCommandID = commandID; isCancelling = false; errorMessage = nil; notice = nil
        executionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await provider.runVerification(commandID: commandID)
                if token == generation { selectedReceiptID = receipt.id }
            } catch {
                if token == generation {
                    if error is CancellationError { notice = "검증 실행을 취소했습니다." }
                    else { errorMessage = error.localizedDescription }
                }
            }
            // A fresh task does not inherit cancellation. Reload the durable cancelled
            // receipt after the runner has stopped instead of leaving a false green state.
            let result = await Task { @MainActor [provider] in
                try await provider.loadVerification()
            }.result
            guard token == generation else { return }
            switch result {
            case let .success(loaded): applySnapshot(loaded); verificationError = nil
            case let .failure(error):
                snapshot = nil; verificationError = "실행 후 상태를 불러오지 못했습니다: \(error.localizedDescription)"
            }
            runningCommandID = nil; isCancelling = false; executionTask = nil
        }
    }

    func cancelRun() {
        guard isRunning else { return }
        isCancelling = true; executionTask?.cancel()
    }

    func retryWorkflowLoad() async {
        guard !isBusy, !hasLoadedWorkflow else { return }
        isLoading = true
        await readWorkflow()
        isLoading = false
    }

    private func readWorkflow() async {
        let token = generation
        workflowError = nil
        do {
            let loaded = try await provider.loadWorkflow()
            guard token == generation, !Task.isCancelled else { return }
            if let loaded { plan = loaded; savedPlan = loaded; selectedPreset = loaded.preset }
            hasLoadedWorkflow = true
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            workflowError = "작업 절차를 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func applySnapshot(_ loaded: VerificationSnapshot, replaceDrafts: Bool = false) {
        let drafts = loaded.profile.commands.map(WorkspaceVerificationCommandDraft.init)
        if replaceDrafts || !isProfileDirty { commandDrafts = drafts }
        savedCommandDrafts = drafts
        snapshot = loaded
    }

    func close() {
        generation = UUID(); refreshGeneration = UUID()
        executionTask?.cancel(); executionTask = nil
    }
}
