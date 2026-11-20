import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceLaunchPreferencesTests: XCTestCase {
    func testOpeningSheetLoadsBranchesAndProviderOptions() async {
        let source = LaunchPreferenceDataSource()
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        await model.prepareNewSession()
        XCTAssertEqual(model.sessionBranchesPhase, .ready)
        XCTAssertEqual(model.sessionOptionsPhase, .ready)
        XCTAssertEqual(model.sessionOptions, source.providers)
        XCTAssertEqual(source.optionReadCount, 1)
    }

    func testBranchRetryDoesNotInvalidatePendingProviderRead() async {
        let source = LaunchPreferenceDataSource()
        source.holdNextOptionsRead = true
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        let opening = Task { await model.prepareNewSession() }
        await source.waitUntilOptionsReadIsHeld()

        await model.retrySessionBranches()
        source.finishHeldOptionsRead(with: source.providers)
        await opening.value

        XCTAssertEqual(model.sessionBranchesPhase, .ready)
        XCTAssertEqual(model.sessionOptionsPhase, .ready)
        XCTAssertEqual(model.sessionOptions, source.providers)
    }

    func testDismissedProviderResponseCannotOverwriteNewPresentation() async {
        let source = LaunchPreferenceDataSource()
        let oldOptions = source.providers
        source.holdNextOptionsRead = true
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        let firstOpening = Task { await model.prepareNewSession() }
        await source.waitUntilOptionsReadIsHeld()
        model.dismissNewSession()

        source.providers = [oldOptions[1]]
        await model.prepareNewSession()
        XCTAssertEqual(model.sessionOptions, source.providers)
        source.finishHeldOptionsRead(with: oldOptions)
        await firstOpening.value

        XCTAssertTrue(model.isPresentingNewSession)
        XCTAssertEqual(model.sessionOptionsPhase, .ready)
        XCTAssertEqual(model.sessionOptions, source.providers)
        XCTAssertEqual(source.optionReadCount, 2)
    }

    func testPreferencesSurviveRelaunchAndStayScopedToProject() throws {
        let suite = "byori.launch-preferences.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WorkspaceLaunchPreferencesStore(defaults: defaults)
        let choice = WorkspaceRememberedLaunch(providerID: "claude", modelID: "custom", customModelID: "opus-test")
        first.remember(choice, for: "project-a")

        let reopened = WorkspaceLaunchPreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.selection(for: "project-a"), choice)
        XCTAssertNil(reopened.selection(for: "project-b"))
        XCTAssertNil(WorkspaceLaunchPreferencesStore().selection(for: "project-a"))
    }

    func testUnavailableProviderIsNotRestoredAndRemovedModelFallsBackSafely() {
        let source = LaunchPreferenceDataSource()
        let missing = WorkspaceRememberedLaunch(providerID: "removed", modelID: "default", customModelID: "")
        XCTAssertNil(missing.validated(in: source.providers))

        var unavailable = source.providers
        unavailable[0].availability = .unavailable(reason: "Not installed")
        let saved = WorkspaceRememberedLaunch(providerID: "claude", modelID: "custom", customModelID: "opus-test")
        XCTAssertNil(saved.validated(in: unavailable))

        let removedModel = WorkspaceRememberedLaunch(providerID: "claude", modelID: "retired", customModelID: "")
        XCTAssertEqual(removedModel.validated(in: source.providers), .init(providerID: "claude", modelID: "default", customModelID: ""))
    }

    func testOpeningAndCancellingDoesNotSaveSelectionsOrCarryConsent() async {
        let source = LaunchPreferenceDataSource()
        let preferences = WorkspaceLaunchPreferencesStore()
        let remembered = WorkspaceRememberedLaunch(providerID: "claude", modelID: "custom", customModelID: "opus-test")
        preferences.remember(remembered, for: "project-a")
        let model = WorkspaceViewModel(dataSource: source, launchPreferences: preferences)
        await model.load()
        await model.prepareNewSession()
        XCTAssertEqual(model.newSessionDraft.providerID, "claude")
        XCTAssertEqual(model.newSessionDraft.modelID, "custom")
        XCTAssertEqual(model.newSessionDraft.customModelID, "opus-test")

        model.chooseProvider("codex")
        model.newSessionDraft.additionalArguments = "--dangerously-bypass-approvals-and-sandbox"
        model.newSessionDraft.launchOptionSelections = ["permission": "unsafe"]
        model.newSessionDraft.acceptsModifiedWorkingTree = true
        model.dismissNewSession()
        await model.prepareNewSession()

        XCTAssertEqual(model.newSessionDraft.providerID, "claude")
        XCTAssertEqual(preferences.selection(for: "project-a"), remembered)
        XCTAssertTrue(model.newSessionDraft.additionalArguments.isEmpty)
        XCTAssertTrue(model.newSessionDraft.launchOptionSelections.isEmpty)
        XCTAssertFalse(model.newSessionDraft.acceptsModifiedWorkingTree)
        XCTAssertEqual(source.launchCount, 0)
    }

    func testSuccessfulLaunchIsRememberedButFailureDoesNotReplaceIt() async {
        let source = LaunchPreferenceDataSource()
        let preferences = WorkspaceLaunchPreferencesStore()
        let first = WorkspaceViewModel(dataSource: source, launchPreferences: preferences)
        await first.load()
        await first.prepareNewSession()
        first.newSessionDraft.newTaskTitle = "Fix navigation"
        first.chooseProvider("claude")
        first.chooseModel("custom")
        first.newSessionDraft.customModelID = "  opus-test  "
        await first.startSession()
        let saved = WorkspaceRememberedLaunch(providerID: "claude", modelID: "custom", customModelID: "opus-test")
        XCTAssertEqual(preferences.selection(for: "project-a"), saved)

        source.shouldFail = true
        let second = WorkspaceViewModel(dataSource: source, launchPreferences: preferences)
        await second.load()
        await second.prepareNewSession()
        second.newSessionDraft.newTaskTitle = "Try another agent"
        second.chooseProvider("codex")
        await second.startSession()
        XCTAssertNotNil(second.newSessionError)
        XCTAssertEqual(preferences.selection(for: "project-a"), saved)
        XCTAssertEqual(source.launchCount, 2)
    }

    func testChangingProviderClearsCustomArgumentsAndUsesOnlyAvailableSingleModel() async {
        let source = LaunchPreferenceDataSource()
        let model = WorkspaceViewModel(dataSource: source)
        await model.load()
        await model.prepareNewSession()
        model.chooseProvider("claude")
        model.chooseModel("custom")
        model.newSessionDraft.customModelID = "opus-test"
        model.newSessionDraft.additionalArguments = "--dangerously-skip-permissions"
        model.newSessionDraft.launchOptionSelections = ["permission": "unsafe"]

        model.chooseProvider("codex")
        XCTAssertEqual(model.newSessionDraft.modelID, "default")
        XCTAssertTrue(model.newSessionDraft.customModelID.isEmpty)
        XCTAssertTrue(model.newSessionDraft.additionalArguments.isEmpty)
        XCTAssertTrue(model.newSessionDraft.launchOptionSelections.isEmpty)

        model.chooseProvider("unavailable")
        XCTAssertNil(model.newSessionDraft.modelID)
    }

    func testProviderRefreshValidatesRememberedChoiceBeforeApplyingIt() async {
        let source = LaunchPreferenceDataSource()
        source.providers[0].availability = .unavailable(reason: "Not installed")
        let preferences = WorkspaceLaunchPreferencesStore()
        preferences.remember(.init(providerID: "claude", modelID: "default", customModelID: ""), for: "project-a")
        let model = WorkspaceViewModel(dataSource: source, launchPreferences: preferences)
        await model.load()
        await model.prepareNewSession()
        XCTAssertNil(model.newSessionDraft.providerID)
        XCTAssertNil(model.newSessionDraft.modelID)
    }
}

@MainActor
private final class LaunchPreferenceDataSource: WorkspaceDataSource {
    var shouldFail = false
    var launchCount = 0
    var optionReadCount = 0
    var holdNextOptionsRead = false
    private var heldOptionsRead: CheckedContinuation<[WorkspaceProviderOption], Error>?
    private var optionsReadStarted: CheckedContinuation<Void, Never>?
    var providers: [WorkspaceProviderOption] = [
        .init(id: "claude", displayName: "Claude Code", systemImage: "terminal", availability: .available, models: [
            .init(id: "default", displayName: "CLI default", availability: .available),
            .init(id: "custom", displayName: "Custom", availability: .available, acceptsCustomIdentifier: true),
        ]),
        .init(id: "codex", displayName: "Codex", systemImage: "terminal", availability: .available, models: [
            .init(id: "default", displayName: "CLI default", availability: .available),
            .init(id: "unavailable-model", displayName: "Unavailable", availability: .unavailable(reason: "Unavailable")),
        ]),
        .init(id: "unavailable", displayName: "Unavailable", systemImage: "terminal", availability: .unavailable(reason: "Not installed"), models: [
            .init(id: "default", displayName: "CLI default", availability: .unavailable(reason: "Not installed")),
        ]),
    ]

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        .init(projects: [
            .init(id: "project-a", name: "Byori", repositoryURL: URL(fileURLWithPath: "/tmp/byori-launch-preferences"),
                  memorySpace: "byori_project_a", registration: .trusted, sourceTrees: [
                    .init(id: "tree-a", projectID: "project-a", name: "feature/test", url: URL(fileURLWithPath: "/tmp/byori-launch-preferences"),
                          kind: .primary, branch: "feature/test", headRevision: String(repeating: "a", count: 40), workingState: .clean, tasks: []),
                  ], hiddenSourceTrees: []),
        ])
    }

    func waitUntilOptionsReadIsHeld() async {
        guard heldOptionsRead == nil else { return }
        await withCheckedContinuation { optionsReadStarted = $0 }
    }

    func finishHeldOptionsRead(with options: [WorkspaceProviderOption]) {
        let continuation = heldOptionsRead
        heldOptionsRead = nil
        continuation?.resume(returning: options)
    }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] {
        optionReadCount += 1
        guard holdNextOptionsRead else { return providers }
        holdNextOptionsRead = false
        return try await withCheckedThrowingContinuation { continuation in
            heldOptionsRead = continuation
            optionsReadStarted?.resume()
            optionsReadStarted = nil
        }
    }
    func branches(projectID: String) async throws -> [WorkspaceGitBranch] {
        [.init(name: "feature/test", isRemote: false, isCheckedOut: true)]
    }
    func sessionPersistenceWarning() async -> String? { nil }

    func startSession(_ request: WorkspaceSessionLaunchRequest) async throws -> WorkspaceSessionLaunchResult {
        launchCount += 1
        if shouldFail { throw WorkspaceAdapterError.invalidState("Launch failed") }
        let session = WorkspaceSessionItem(
            id: "session-\(launchCount)", taskID: "task-\(launchCount)", name: request.sessionName,
            providerID: request.providerID, providerName: "Test agent", providerSystemImage: "terminal",
            modelID: "custom", modelName: "opus-test", state: .completed, statusDetail: nil,
            startedAt: Date(), endedAt: Date(), nativeSessionID: nil
        )
        let task = WorkspaceTaskItem(id: session.taskID, sourceTreeID: request.sourceTreeID,
                                     title: request.newTaskTitle ?? "Task", status: .open, createdAt: Date(), sessions: [session])
        return .init(projectID: request.projectID, sourceTreeID: request.sourceTreeID, task: task, session: session)
    }
}
