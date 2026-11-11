import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceTaskWorkViewModelTests: XCTestCase {
    func testOpeningRestoresPlanAndCommandsWithoutRunning() async {
        let provider = TaskWorkFixtureProvider()
        var plan = TaskWorkflowPreset.bugFix.makePlan(goal: "복구")
        plan.notes = "기존 메모"; plan.steps[0].completed = true
        provider.workflow = plan
        let model = makeModel(provider)
        await model.load()

        XCTAssertEqual(model.plan, plan)
        XCTAssertEqual(model.selectedPreset, .bugFix)
        XCTAssertFalse(model.isWorkflowDirty)
        XCTAssertFalse(model.isProfileDirty)
        XCTAssertEqual(model.commandDrafts.map(\.id), ["test-command"])
        XCTAssertEqual(provider.runCalls, [])
        XCTAssertEqual(model.snapshot?.requiredAssessment.state, .notRun)
    }

    func testPresetSelectionDoesNotReplacePlanUntilExplicitApplyAndSave() async {
        let provider = TaskWorkFixtureProvider()
        provider.workflow = TaskWorkflowPreset.feature.makePlan(goal: "기존 목표")
        let model = makeModel(provider)
        await model.load()
        model.plan.notes = "미저장 내용"
        model.selectedPreset = .codeReview

        XCTAssertEqual(model.plan.preset, .feature)
        XCTAssertTrue(model.hasWorkflowToReplace)
        XCTAssertTrue(provider.savedWorkflows.isEmpty)
        model.applyPreset()
        XCTAssertEqual(model.plan.preset, .codeReview)
        XCTAssertEqual(model.plan.goal, "기존 목표")
        XCTAssertTrue(model.isWorkflowDirty)
        await model.saveWorkflow()
        XCTAssertEqual(provider.savedWorkflows, [model.plan])
        XCTAssertFalse(model.isWorkflowDirty)
    }

    func testManualChecklistDoesNotTurnUnrunVerificationGreen() async {
        let provider = TaskWorkFixtureProvider()
        let model = makeModel(provider)
        await model.load()
        for index in model.plan.steps.indices { model.plan.steps[index].completed = true }
        await model.saveWorkflow()

        XCTAssertEqual(model.snapshot?.requiredAssessment.state, .notRun)
        XCTAssertTrue(model.handoffText.contains("미실행"))
        XCTAssertTrue(provider.runCalls.isEmpty)
    }

    func testDirtyCommandsCannotRunAndExplicitSavePreservesArgumentBoundaries() async {
        let provider = TaskWorkFixtureProvider()
        let model = makeModel(provider)
        await model.load()
        model.commandDrafts[0].argumentsText = "test\na path with spaces\n|\n'quoted'\n"
        XCTAssertTrue(model.isProfileDirty)
        XCTAssertFalse(model.canRun)
        XCTAssertTrue(model.handoffText.contains("저장하지 않은 변경"))
        model.run(commandID: "test-command")
        XCTAssertTrue(provider.runCalls.isEmpty)

        await model.saveCommands()
        XCTAssertEqual(provider.savedCommands.first?.first?.arguments, ["test", "a path with spaces", "|", "'quoted'"])
        XCTAssertFalse(model.isProfileDirty)
        XCTAssertTrue(provider.runCalls.isEmpty)
        model.run(commandID: "test-command")
        await waitUntilFinished(model)
        XCTAssertEqual(provider.runCalls, ["test-command"])
        XCTAssertEqual(model.snapshot?.requiredAssessment.state, .passed)
    }

    func testInvalidTimeoutDoesNotSaveAndStarterDoesNotExecute() async {
        let provider = TaskWorkFixtureProvider()
        let model = makeModel(provider)
        await model.load()
        model.addCommand(.python)
        XCTAssertEqual(model.commandDrafts.last?.argumentsText, "-m\npytest")
        model.commandDrafts[0].timeoutText = "1801"
        await model.saveCommands()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(provider.savedCommands.isEmpty)
        XCTAssertTrue(provider.runCalls.isEmpty)
    }

    func testCommandRoundTripRetainsExistingEmptyAndMultilineArguments() throws {
        let command = VerificationCommand(name: "literal", executable: "tool", arguments: ["", "first\nsecond"], timeout: 1.5)
        var draft = WorkspaceVerificationCommandDraft(command)
        draft.name = "renamed"
        let result = try draft.command()
        XCTAssertEqual(result.arguments, command.arguments)
        XCTAssertEqual(result.timeout, 1.5)
    }

    func testStaleSuccessKeepsHistoricalOutputWithoutClaimingCurrentPass() async {
        let provider = TaskWorkFixtureProvider()
        let old = provider.fingerprint("old")
        let receipt = provider.receipt(outcome: .passed, fingerprint: old, output: "old successful output")
        provider.snapshot = .init(scope: provider.scope, profile: provider.snapshot.profile,
                                  receipts: [receipt], current: provider.fingerprint("edited"))
        let model = makeModel(provider)
        await model.load()

        XCTAssertEqual(model.snapshot?.requiredAssessment.state, .stale)
        XCTAssertEqual(model.selectedReceipt?.output, "old successful output")
        XCTAssertTrue(model.handoffText.contains("코드·설정 변경"))
        XCTAssertTrue(model.handoffText.contains("확인 시각:"))
        XCTAssertTrue(model.handoffText.contains("확인 이후의 코드·설정 변경은 이 인계문에 반영되지 않습니다"))
    }

    func testCancellationWaitsForRunnerAndReloadsDurableCancelledReceipt() async {
        let provider = TaskWorkFixtureProvider()
        provider.holdRun = true
        let model = makeModel(provider)
        await model.load()
        model.run(commandID: "test-command")
        for _ in 0..<1_000 where !provider.runStarted { await Task.yield() }
        XCTAssertTrue(provider.runStarted)
        model.cancelRun()
        XCTAssertTrue(model.isCancelling)
        await waitUntilFinished(model)

        XCTAssertTrue(provider.runCancelled)
        XCTAssertFalse(model.isCancelling)
        XCTAssertEqual(model.snapshot?.requiredAssessment.state, .cancelled)
        XCTAssertEqual(model.selectedReceipt?.output, "partial output")
        XCTAssertNil(model.verificationError)
    }

    func testRunErrorAndRefreshErrorAreVisibleWithoutLeavingBusyState() async {
        let provider = TaskWorkFixtureProvider()
        let model = makeModel(provider)
        await model.load()
        provider.failRun = true; provider.failVerification = true
        model.run(commandID: "test-command")
        await waitUntilFinished(model)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotNil(model.verificationError)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRun)
        XCTAssertTrue(model.handoffText.contains("확인하지 못했습니다"))
    }

    func testWorkflowReadFailureCannotOverwriteUnknownSavedPlanAndCanRetry() async {
        let provider = TaskWorkFixtureProvider()
        provider.failWorkflow = true
        let model = makeModel(provider)
        await model.load()
        await model.saveWorkflow()
        XCTAssertFalse(model.hasLoadedWorkflow)
        XCTAssertNotNil(model.workflowError)
        XCTAssertTrue(provider.savedWorkflows.isEmpty)
        XCTAssertNotNil(model.snapshot)

        provider.failWorkflow = false
        provider.workflow = TaskWorkflowPreset.codeReview.makePlan(goal: "기존 절차")
        await model.retryWorkflowLoad()
        XCTAssertTrue(model.hasLoadedWorkflow)
        XCTAssertEqual(model.plan.goal, "기존 절차")
        XCTAssertNil(model.workflowError)
    }

    func testOlderRefreshCannotReplaceNewerSnapshotOrDiscardEditedCommands() async {
        let provider = TaskWorkFixtureProvider()
        let model = makeModel(provider)
        await model.load()
        let old = provider.snapshot
        provider.holdNextVerification = true
        let pending = Task { await model.refreshVerification() }
        for _ in 0..<1_000 where provider.heldVerification == nil { await Task.yield() }
        XCTAssertNotNil(provider.heldVerification)
        model.commandDrafts[0].name = "local edit"
        let receipt = provider.receipt(outcome: .failed, output: "new failure")
        provider.snapshot = .init(scope: provider.scope, profile: old.profile,
                                  receipts: [receipt], current: old.current)
        await model.refreshVerification()
        provider.heldVerification?.resume(returning: old); provider.heldVerification = nil
        await pending.value

        XCTAssertEqual(model.selectedReceipt?.output, "new failure")
        XCTAssertEqual(model.snapshot?.requiredAssessment.state, .failed)
        XCTAssertEqual(model.commandDrafts[0].name, "local edit")
        XCTAssertTrue(model.isProfileDirty)
        XCTAssertFalse(model.isRefreshing)
    }

    func testRefreshingAdoptsChangedSavedProfileBeforeAllowingRun() async {
        let provider = TaskWorkFixtureProvider()
        let model = makeModel(provider)
        await model.load()
        var command = provider.snapshot.profile.commands[0]
        command.arguments = ["changed"]
        provider.snapshot = .init(scope: provider.scope, profile: .init(commands: [command]),
                                  receipts: [], current: provider.snapshot.current)
        await model.refreshVerification()
        XCTAssertEqual(model.commandDrafts[0].argumentsText, "changed")
        XCTAssertFalse(model.isProfileDirty)
    }

    private func makeModel(_ provider: TaskWorkFixtureProvider) -> WorkspaceTaskWorkViewModel {
        .init(scope: .init(projectID: "project", sourceTreeID: "checkout", taskID: "task",
                           taskTitle: "작업", title: "프로젝트 · checkout · 작업", root: provider.scope.root),
              provider: provider)
    }

    private func waitUntilFinished(_ model: WorkspaceTaskWorkViewModel) async {
        for _ in 0..<2_000 where model.isRunning { await Task.yield() }
        XCTAssertFalse(model.isRunning)
    }
}

@MainActor
private final class TaskWorkFixtureProvider: WorkspaceTaskWorkProviding {
    let scope = VerificationScope(projectID: "project", checkoutID: "checkout", taskID: "task",
                                  root: URL(fileURLWithPath: "/private/tmp/task-work-fixture"))
    var workflow: TaskWorkflowPlan?
    var snapshot: VerificationSnapshot
    var savedWorkflows: [TaskWorkflowPlan] = []
    var savedCommands: [[VerificationCommand]] = []
    var runCalls: [String] = []
    var failWorkflow = false
    var failVerification = false
    var failRun = false
    var holdRun = false
    var runStarted = false
    var runCancelled = false
    var holdNextVerification = false
    var heldVerification: CheckedContinuation<VerificationSnapshot, any Error>?

    init() {
        snapshot = .init(scope: scope, profile: .init(commands: [
            .init(id: "test-command", name: "Test", executable: "test-tool", arguments: ["test"])
        ]), receipts: [], current: .init(root: scope.root.path, revision: "revision", digest: "current", complete: true))
    }

    func fingerprint(_ digest: String) -> VerificationFingerprint {
        .init(root: scope.root.path, revision: "revision", digest: digest, complete: true)
    }

    func receipt(outcome: VerificationOutcome, fingerprint: VerificationFingerprint? = nil,
                 output: String = "test output") -> VerificationReceipt {
        .init(scope: scope, command: snapshot.profile.commands[0], resolvedExecutable: "/fake/test-tool",
              finishedAt: Date(), outcome: outcome, exitCode: outcome == .passed ? 0 : 1,
              before: fingerprint ?? snapshot.current, after: fingerprint ?? snapshot.current, output: output)
    }

    func loadWorkflow() async throws -> TaskWorkflowPlan? {
        if failWorkflow { throw FixtureError.failed }
        return workflow
    }

    func saveWorkflow(_ plan: TaskWorkflowPlan) async throws { savedWorkflows.append(plan); workflow = plan }

    func loadVerification() async throws -> VerificationSnapshot {
        try Task.checkCancellation()
        if failVerification { throw FixtureError.failed }
        if holdNextVerification {
            holdNextVerification = false
            return try await withCheckedThrowingContinuation { heldVerification = $0 }
        }
        return snapshot
    }

    func saveVerificationCommands(_ commands: [VerificationCommand]) async throws {
        savedCommands.append(commands)
        snapshot = .init(scope: scope, profile: .init(commands: commands), receipts: snapshot.receipts, current: snapshot.current)
    }

    func runVerification(commandID: String) async throws -> VerificationReceipt {
        runCalls.append(commandID); runStarted = true
        if failRun { throw FixtureError.failed }
        if holdRun {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch {
                runCancelled = true
                let cancelled = receipt(outcome: .cancelled, output: "partial output")
                snapshot = .init(scope: scope, profile: snapshot.profile, receipts: [cancelled], current: snapshot.current)
                throw error
            }
        }
        let completed = receipt(outcome: .passed)
        snapshot = .init(scope: scope, profile: snapshot.profile, receipts: [completed], current: snapshot.current)
        return completed
    }

    private enum FixtureError: Error { case failed }
}
