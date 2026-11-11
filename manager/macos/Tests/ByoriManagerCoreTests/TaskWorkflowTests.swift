import XCTest
@testable import ByoriManagerCore

final class TaskWorkflowTests: XCTestCase {
    func testThreePresetsHaveDistinctStepsAndHonestHandoff() throws {
        XCTAssertEqual(TaskWorkflowPreset.allCases.count, 3)
        for preset in TaskWorkflowPreset.allCases {
            let plan = preset.makePlan(goal: "선택한 작업")
            try plan.validate()
            XCTAssertEqual(plan.preset, preset)
            XCTAssertFalse(plan.steps.contains(where: \.completed))
            XCTAssertTrue(plan.handoffText.contains("실제 검증 실행 결과와 별도"))
            XCTAssertEqual(Set(plan.steps.map(\.id)).count, plan.steps.count)
        }
    }

    func testRoundTripPrivateSidecarAndScopeChecks() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("byori-workflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let tasks = WorkspaceTaskStore(home: home)
        let task = try await tasks.createTask(projectID: "project", checkout: .init(kind: .worktree, id: "tree"), title: "Repair")
        let scope = VerificationScope(projectID: "project", checkoutID: "tree", taskID: task.id, root: home)
        let store = TaskWorkflowStore(home: home)
        XCTAssertNil(try store.load(scope: scope))
        var plan = TaskWorkflowPreset.bugFix.makePlan(goal: task.title)
        plan.steps[0].completed = true
        plan.notes = "재현 근거와 후속 작업"
        try store.save(plan, scope: scope)
        XCTAssertEqual(try store.load(scope: scope), plan)
        let file = home.appendingPathComponent("tasks/\(task.id)/workflow.json")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let wrongScope = VerificationScope(projectID: "other", checkoutID: "tree", taskID: task.id, root: home)
        XCTAssertThrowsError(try store.load(scope: wrongScope))
        XCTAssertThrowsError(try store.save(plan, scope: wrongScope))
        XCTAssertEqual(try store.load(scope: scope), plan)

        _ = try await tasks.archiveTask(id: task.id)
        XCTAssertThrowsError(try store.save(plan, scope: scope))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("archived-tasks/\(task.id)/workflow.json").path))
    }

    func testMalformedAndSymlinkedWorkflowNeverLoadsAsEmpty() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("byori-workflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let task = try await WorkspaceTaskStore(home: home).createTask(projectID: "project", checkout: .init(kind: .sourceTree, id: "tree"), title: "Review")
        let scope = VerificationScope(projectID: "project", checkoutID: "tree", taskID: task.id, root: home)
        let store = TaskWorkflowStore(home: home)
        let file = home.appendingPathComponent("tasks/\(task.id)/workflow.json")
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try store.load(scope: scope))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: home.appendingPathComponent("missing"))
        XCTAssertThrowsError(try store.load(scope: scope))
        XCTAssertThrowsError(try store.save(TaskWorkflowPreset.codeReview.makePlan(goal: "Review"), scope: scope))
    }

    func testInvalidPlanDoesNotReplaceSavedPlan() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("byori-workflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let task = try await WorkspaceTaskStore(home: home).createTask(projectID: "project", checkout: .init(kind: .sourceTree, id: "tree"), title: "Feature")
        let scope = VerificationScope(projectID: "project", checkoutID: "tree", taskID: task.id, root: home)
        let store = TaskWorkflowStore(home: home)
        let original = TaskWorkflowPreset.feature.makePlan(goal: "Feature")
        try store.save(original, scope: scope)
        var invalid = original
        invalid.goal = " "
        XCTAssertThrowsError(try store.save(invalid, scope: scope))
        invalid = original
        invalid.notes = String(repeating: "x", count: 32_001)
        XCTAssertThrowsError(try store.save(invalid, scope: scope))
        invalid = original
        invalid.steps.append(original.steps[0])
        XCTAssertThrowsError(try store.save(invalid, scope: scope))
        XCTAssertEqual(try store.load(scope: scope), original)
    }
}
