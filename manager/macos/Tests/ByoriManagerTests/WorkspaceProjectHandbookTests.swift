import ByoriManagerCore
import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceProjectHandbookTests: XCTestCase {
    func testProjectSwitchNeverRendersThePriorProjectsInFlightPreview() async throws {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        dataSource.loadRequests.removeAll()
        dataSource.delayedProjectID = "project-a"

        model.select(.project("project-b"))
        for _ in 0..<200 where model.projectHandbook?.handbook != "Handbook for project-b" {
            await Task.yield()
        }
        model.select(.project("project-a"))
        for _ in 0..<200 where !dataSource.loadRequests.contains("project-a") {
            await Task.yield()
        }

        model.select(.project("project-b"))
        for _ in 0..<200 where model.projectHandbook?.handbook != "Handbook for project-b" {
            await Task.yield()
        }
        XCTAssertEqual(model.selection, .project("project-b"))
        XCTAssertEqual(model.projectHandbook?.handbook, "Handbook for project-b")

        dataSource.releaseDelayedLoad()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(model.selection, .project("project-b"))
        XCTAssertEqual(model.projectHandbook?.handbook, "Handbook for project-b")
        XCTAssertEqual(model.projectHandbook?.generation, "generation-project-b")
    }

    func testSelectingAProjectMakesItsHandbookTheLoadedPrimaryState() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        model.select(.project("project-a"))
        for _ in 0..<200 where model.projectHandbook == nil {
            await Task.yield()
        }

        XCTAssertTrue(model.isProjectSelected)
        XCTAssertEqual(model.handbookPhase, .ready)
        XCTAssertEqual(model.projectHandbook?.handbook, "Handbook for project-a")
        XCTAssertEqual(dataSource.loadRequests.last, "project-a")
    }

    func testAProjectIsTheDefaultWhenThereIsNoActiveSession() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        let model = WorkspaceViewModel(dataSource: dataSource)

        await model.load()

        XCTAssertEqual(model.selection, .project("project-a"))
        XCTAssertEqual(model.projectHandbook?.handbook, "Handbook for project-a")
    }

    func testBuildKeepsAReportedStaleStateInsteadOfClaimingCurrent() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        dataSource.buildSnapshot = handbook(for: "project-a", freshness: .stale)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        model.select(.project("project-a"))
        for _ in 0..<200 where model.projectHandbook == nil {
            await Task.yield()
        }

        await model.buildSelectedProjectHandbook()

        XCTAssertEqual(dataSource.buildRequests, ["project-a"])
        XCTAssertEqual(model.projectHandbook?.freshness, .stale)
        XCTAssertEqual(model.handbookPhase, .ready)
        XCTAssertNil(model.handbookBuildProjectID)
    }

    func testBuildFailureWithholdsThePreviousContent() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        dataSource.buildError = WorkspaceAdapterError.invalidState("verification failed")
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        model.select(.project("project-a"))
        for _ in 0..<200 where model.projectHandbook == nil {
            await Task.yield()
        }

        await model.buildSelectedProjectHandbook()

        XCTAssertEqual(model.handbookPhase, .failed("verification failed"))
        XCTAssertNil(model.projectHandbook)
        XCTAssertEqual(model.handbookOperationError, "verification failed")
        XCTAssertNil(model.handbookBuildProjectID)
    }

    func testFreshnessCheckWithholdsPreviousContentWhileLoadingAndAfterFailure() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        let requestCount = dataSource.loadRequests.count
        dataSource.delayedProjectID = "project-a"
        dataSource.loadError = WorkspaceAdapterError.invalidState("source scan unavailable")

        let refresh = Task { await model.refreshProjectHandbook() }
        for _ in 0..<200 where dataSource.loadRequests.count == requestCount {
            await Task.yield()
        }

        XCTAssertEqual(model.handbookPhase, .loading)
        XCTAssertNil(model.projectHandbook)

        dataSource.releaseDelayedLoad()
        await refresh.value

        XCTAssertEqual(model.handbookPhase, .failed("source scan unavailable"))
        XCTAssertNil(model.projectHandbook)
        XCTAssertEqual(model.handbookOperationError, "source scan unavailable")
    }

    func testConnectionRequiresPreviewBeforeExplicitApply() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.reviewProjectHandbookConnection(.claude)

        XCTAssertEqual(dataSource.connectionPreviewRequests.count, 1)
        XCTAssertTrue(dataSource.connectionApplyRequests.isEmpty)
        XCTAssertEqual(model.pendingHandbookConnectionPreview?.connection.host, .claude)
        XCTAssertEqual(model.handbookConnections[.claude]?.status, .unconfigured)

        await model.applyReviewedProjectHandbookConnection()

        XCTAssertEqual(dataSource.connectionApplyRequests, ["project-a:claude"])
        XCTAssertEqual(model.handbookConnections[.claude]?.status, .configured)
        XCTAssertNil(model.pendingHandbookConnectionPreview)
    }

    func testDisconnectRequiresASeparateConfirmation() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        dataSource.configuredHosts.insert(.codex)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        model.requestProjectHandbookDisconnect(.codex)

        XCTAssertTrue(dataSource.connectionDisconnectRequests.isEmpty)
        XCTAssertEqual(model.pendingHandbookDisconnectHost, .codex)

        await model.confirmProjectHandbookDisconnect()

        XCTAssertEqual(dataSource.connectionDisconnectRequests, ["project-a:codex"])
        XCTAssertEqual(model.handbookConnections[.codex]?.status, .disconnected)
        XCTAssertNil(model.pendingHandbookDisconnectHost)
    }

    func testProjectSwitchDropsAnInFlightConnectionPreview() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        dataSource.delayedConnectionPreviewProjectID = "project-a"

        let previewTask = Task { await model.reviewProjectHandbookConnection(.claude) }
        for _ in 0..<200 where dataSource.connectionPreviewRequests.isEmpty {
            await Task.yield()
        }
        model.select(.project("project-b"))
        for _ in 0..<200 where model.handbookConnections[.claude]?.instructionFile.contains("project-b") != true {
            await Task.yield()
        }
        dataSource.releaseDelayedConnectionPreview()
        await previewTask.value

        XCTAssertEqual(model.selection, .project("project-b"))
        XCTAssertNil(model.pendingHandbookConnectionPreview)
        XCTAssertTrue(model.handbookConnections[.claude]?.instructionFile.contains("project-b") == true)
    }

    func testAutomaticRefreshIsOffByDefaultAndLoadingDoesNotWriteOrSync() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        let model = testModel(dataSource)
        model.setWorkspaceVisible(true)
        model.setSceneActive(true)

        await model.load()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(dataSource.refreshConfigurationReadRequests, ["project-a"])
        XCTAssertTrue(dataSource.refreshSettingRequests.isEmpty)
        XCTAssertTrue(dataSource.syncRequests.isEmpty)
        XCTAssertEqual(model.handbookRefreshConfiguration?.enabled, false)
        XCTAssertEqual(model.projectHandbook?.handbook, "Handbook for project-a")
    }

    func testEnablingWritesConsentThenImmediatelySyncsTheVisibleProject() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        let model = testModel(dataSource)
        model.setWorkspaceVisible(true)
        model.setSceneActive(true)
        await model.load()

        await model.setProjectHandbookAutomaticRefresh(true)
        for _ in 0..<200 where dataSource.syncRequests.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(dataSource.refreshSettingRequests, ["project-a:true:nil"])
        XCTAssertEqual(dataSource.syncRequests, ["project-a"])
        XCTAssertEqual(model.handbookRefreshConfiguration?.enabled, true)
        XCTAssertEqual(model.projectHandbook?.handbook, "Synced handbook for project-a")
        XCTAssertTrue(dataSource.buildRequests.isEmpty)
    }

    func testDisablingCallsExplicitSetterAndStopsFurtherAutomaticSync() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        dataSource.refreshConfigurations["project-a"] = refreshConfiguration(
            for: "project-a",
            enabled: true,
            revision: String(repeating: "a", count: 64)
        )
        let model = testModel(dataSource)
        model.setWorkspaceVisible(true)
        model.setSceneActive(true)
        await model.load()
        for _ in 0..<200 where dataSource.syncRequests.isEmpty {
            await Task.yield()
        }

        await model.setProjectHandbookAutomaticRefresh(false)
        let countAfterDisable = dataSource.syncRequests.count
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(dataSource.refreshSettingRequests, [
            "project-a:false:\(String(repeating: "a", count: 64))",
        ])
        XCTAssertEqual(dataSource.syncRequests.count, countAfterDisable)
        XCTAssertEqual(model.handbookRefreshConfiguration?.enabled, false)
        XCTAssertEqual(model.projectHandbook?.handbook, "Handbook for project-a")
    }

    func testExplicitRefreshUsesOneShotRefreshAndNeverLegacyBuild() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        let model = testModel(dataSource)
        await model.load()

        await model.refreshSelectedProjectHandbookNow()

        XCTAssertEqual(dataSource.explicitRefreshRequests, ["project-a"])
        XCTAssertTrue(dataSource.buildRequests.isEmpty)
        XCTAssertEqual(model.projectHandbook?.handbook, "Refreshed handbook for project-a")
        XCTAssertEqual(model.projectHandbook?.buildChanged, true)
    }

    func testProjectSwitchCancelsAutomaticResultAndNeverSyncsDisabledDestination() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        dataSource.refreshConfigurations["project-a"] = refreshConfiguration(
            for: "project-a",
            enabled: true,
            revision: String(repeating: "a", count: 64)
        )
        dataSource.delayedSyncProjectID = "project-a"
        let model = testModel(dataSource)
        model.setWorkspaceVisible(true)
        model.setSceneActive(true)
        await model.load()
        for _ in 0..<200 where dataSource.syncRequests.isEmpty {
            await Task.yield()
        }

        model.select(.project("project-b"))
        for _ in 0..<200 where model.projectHandbook?.handbook != "Handbook for project-b" {
            await Task.yield()
        }
        dataSource.releaseDelayedSync()
        for _ in 0..<40 { await Task.yield() }

        XCTAssertEqual(model.selection, .project("project-b"))
        XCTAssertEqual(model.projectHandbook?.handbook, "Handbook for project-b")
        XCTAssertEqual(dataSource.syncRequests, ["project-a"])
    }

    func testInactiveSceneCancelsLoopWithholdsBodyAndRestartsWithImmediateSync() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        dataSource.refreshConfigurations["project-a"] = refreshConfiguration(
            for: "project-a",
            enabled: true,
            revision: String(repeating: "a", count: 64)
        )
        dataSource.delayedSyncProjectID = "project-a"
        let model = testModel(dataSource)
        model.setWorkspaceVisible(true)
        model.setSceneActive(true)
        await model.load()
        for _ in 0..<200 where dataSource.syncRequests.isEmpty {
            await Task.yield()
        }

        XCTAssertNil(model.projectHandbook)
        XCTAssertEqual(model.handbookPhase, .loading)
        model.setSceneActive(false)
        XCTAssertNil(model.projectHandbook)
        XCTAssertEqual(model.handbookPhase, .idle)
        dataSource.releaseDelayedSync()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertNil(model.projectHandbook)
        XCTAssertEqual(dataSource.syncRequests.count, 1)

        dataSource.delayedSyncProjectID = nil
        model.setSceneActive(true)
        for _ in 0..<200 where dataSource.syncRequests.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(dataSource.syncRequests.count, 2)
        XCTAssertEqual(model.projectHandbook?.handbook, "Synced handbook for project-a")
    }

    func testRepeatedVisibilitySignalsCoalesceOneInFlightAutomaticSync() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        dataSource.refreshConfigurations["project-a"] = refreshConfiguration(
            for: "project-a",
            enabled: true,
            revision: String(repeating: "a", count: 64)
        )
        dataSource.delayedSyncProjectID = "project-a"
        let model = testModel(dataSource)
        model.setWorkspaceVisible(true)
        model.setSceneActive(true)
        await model.load()
        for _ in 0..<200 where dataSource.syncRequests.isEmpty {
            await Task.yield()
        }

        model.setWorkspaceVisible(true)
        model.setSceneActive(true)
        model.select(.project("project-a"))
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(dataSource.syncRequests, ["project-a"])
        XCTAssertEqual(dataSource.maximumConcurrentSyncs, 1)
        dataSource.releaseDelayedSync()
    }

    func testPeriodicLoopRunsSeriallyWithInjectedTickAndNoRealSleep() async {
        let dataSource = ProjectHandbookDataSource(snapshot: makeWorkspace())
        dataSource.refreshConfigurations["project-a"] = refreshConfiguration(
            for: "project-a",
            enabled: true,
            revision: String(repeating: "a", count: 64)
        )
        let sleeper = OneTickRefreshSleeper()
        let model = WorkspaceViewModel(
            dataSource: dataSource,
            handbookRefreshSleep: { try await sleeper.sleep() }
        )
        model.setWorkspaceVisible(true)
        model.setSceneActive(true)
        await model.load()
        for _ in 0..<400 where dataSource.syncRequests.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(dataSource.syncRequests, ["project-a", "project-a"])
        XCTAssertEqual(dataSource.maximumConcurrentSyncs, 1)
        model.setWorkspaceVisible(false)
    }

    private func testModel(_ dataSource: ProjectHandbookDataSource) -> WorkspaceViewModel {
        WorkspaceViewModel(
            dataSource: dataSource,
            handbookRefreshSleep: { try await Task.sleep(nanoseconds: .max) }
        )
    }

    private func makeWorkspace() -> WorkspacePresentationSnapshot {
        WorkspacePresentationSnapshot(projects: [project(id: "project-a"), project(id: "project-b")])
    }

    private func project(id: String) -> WorkspaceProjectItem {
        let url = URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true)
        let sourceTree = WorkspaceSourceTreeItem(
            id: "source-\(id)",
            projectID: id,
            name: "main",
            url: url,
            kind: .primary,
            branch: "main",
            headRevision: String(repeating: "a", count: 40),
            workingState: .clean,
            tasks: []
        )
        return WorkspaceProjectItem(
            id: id,
            name: id,
            repositoryURL: url,
            memorySpace: "byori_\(id)",
            registration: .trusted,
            sourceTrees: [sourceTree],
            hiddenSourceTrees: []
        )
    }
}

private actor OneTickRefreshSleeper {
    private var ticksRemaining = 1

    func sleep() async throws {
        if ticksRemaining > 0 {
            ticksRemaining -= 1
            await Task.yield()
            return
        }
        try await Task.sleep(nanoseconds: .max)
    }
}

@MainActor
private final class ProjectHandbookDataSource: WorkspaceDataSource {
    let snapshot: WorkspacePresentationSnapshot
    var delayedProjectID: String?
    var loadRequests: [String] = []
    var buildRequests: [String] = []
    var buildSnapshot: ProjectHandbookSnapshot?
    var buildError: Error?
    var loadError: Error?
    var refreshConfigurations: [String: ProjectHandbookRefreshConfiguration] = [:]
    var refreshConfigurationReadRequests: [String] = []
    var refreshSettingRequests: [String] = []
    var syncRequests: [String] = []
    var explicitRefreshRequests: [String] = []
    var delayedSyncProjectID: String?
    var maximumConcurrentSyncs = 0
    private var activeSyncs = 0
    var configuredHosts: Set<ProjectHandbookHost> = []
    var connectionPreviewRequests: [String] = []
    var connectionApplyRequests: [String] = []
    var connectionDisconnectRequests: [String] = []
    var delayedConnectionPreviewProjectID: String?
    private var delayedContinuation: CheckedContinuation<Void, Never>?
    private var delayedSyncContinuation: CheckedContinuation<Void, Never>?
    private var delayedConnectionPreviewContinuation: CheckedContinuation<Void, Never>?

    init(snapshot: WorkspacePresentationSnapshot) {
        self.snapshot = snapshot
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot { snapshot }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Not used by these tests.")
    }

    func loadProjectHandbook(projectID: String) async throws -> ProjectHandbookSnapshot {
        loadRequests.append(projectID)
        if projectID == delayedProjectID {
            await withCheckedContinuation { continuation in
                delayedContinuation = continuation
            }
        }
        if let loadError { throw loadError }
        return handbook(for: projectID)
    }

    func buildProjectHandbook(projectID: String) async throws -> ProjectHandbookSnapshot {
        buildRequests.append(projectID)
        if let buildError { throw buildError }
        return buildSnapshot ?? handbook(for: projectID)
    }

    func loadProjectHandbookRefreshConfiguration(
        projectID: String
    ) async throws -> ProjectHandbookRefreshConfiguration {
        refreshConfigurationReadRequests.append(projectID)
        return refreshConfigurations[projectID] ?? refreshConfiguration(for: projectID)
    }

    func setProjectHandbookAutomaticRefresh(
        projectID: String,
        enabled: Bool,
        expectedRevision: String?
    ) async throws -> ProjectHandbookRefreshConfiguration {
        refreshSettingRequests.append(
            "\(projectID):\(enabled):\(expectedRevision ?? "nil")"
        )
        let updated = refreshConfiguration(
            for: projectID,
            enabled: enabled,
            revision: String(repeating: enabled ? "b" : "c", count: 64)
        )
        refreshConfigurations[projectID] = updated
        return updated
    }

    func syncProjectHandbook(projectID: String) async throws -> ProjectHandbookRefreshResult {
        syncRequests.append(projectID)
        activeSyncs += 1
        maximumConcurrentSyncs = max(maximumConcurrentSyncs, activeSyncs)
        defer { activeSyncs -= 1 }
        if projectID == delayedSyncProjectID {
            await withCheckedContinuation { continuation in
                delayedSyncContinuation = continuation
            }
        }
        return refreshResult(
            projectID: projectID,
            disposition: .rebuilt,
            handbookPrefix: "Synced handbook"
        )
    }

    func refreshProjectHandbook(projectID: String) async throws -> ProjectHandbookRefreshResult {
        explicitRefreshRequests.append(projectID)
        return refreshResult(
            projectID: projectID,
            disposition: .rebuilt,
            handbookPrefix: "Refreshed handbook"
        )
    }

    func loadProjectHandbookConnections(
        projectID: String
    ) async throws -> [ProjectHandbookConnection] {
        ProjectHandbookHost.allCases.map {
            connection(for: projectID, host: $0, status: configuredHosts.contains($0) ? .configured : .unconfigured)
        }
    }

    func previewProjectHandbookConnection(
        projectID: String,
        host: ProjectHandbookHost
    ) async throws -> ProjectHandbookConnection {
        connectionPreviewRequests.append("\(projectID):\(host.rawValue)")
        if projectID == delayedConnectionPreviewProjectID {
            await withCheckedContinuation { continuation in
                delayedConnectionPreviewContinuation = continuation
            }
        }
        return connection(for: projectID, host: host, status: .unconfigured, preview: true)
    }

    func applyProjectHandbookConnection(
        projectID: String,
        host: ProjectHandbookHost
    ) async throws -> ProjectHandbookConnection {
        connectionApplyRequests.append("\(projectID):\(host.rawValue)")
        configuredHosts.insert(host)
        return connection(for: projectID, host: host, status: .configured, changed: true)
    }

    func disconnectProjectHandbookConnection(
        projectID: String,
        host: ProjectHandbookHost
    ) async throws -> ProjectHandbookConnection {
        connectionDisconnectRequests.append("\(projectID):\(host.rawValue)")
        configuredHosts.remove(host)
        return connection(for: projectID, host: host, status: .disconnected, changed: true)
    }

    func releaseDelayedLoad() {
        delayedContinuation?.resume()
        delayedContinuation = nil
    }

    func releaseDelayedSync() {
        delayedSyncContinuation?.resume()
        delayedSyncContinuation = nil
    }

    func releaseDelayedConnectionPreview() {
        delayedConnectionPreviewContinuation?.resume()
        delayedConnectionPreviewContinuation = nil
    }

    private func connection(
        for projectID: String,
        host: ProjectHandbookHost,
        status: ProjectHandbookConnectionStatus,
        changed: Bool = false,
        preview: Bool = false
    ) -> ProjectHandbookConnection {
        let instruction = host == .claude ? "CLAUDE.md" : "AGENTS.md"
        return ProjectHandbookConnection(
            host: host,
            status: status,
            changed: changed,
            instructionFile: "/tmp/\(projectID)/\(instruction)",
            handbookFile: "/tmp/\(projectID)/.byori/handbook.md",
            handbookPresent: true,
            warnings: [],
            wouldChange: preview ? true : nil,
            managedBlock: preview ? "Run byori handbook show ." : nil
        )
    }

    private func refreshResult(
        projectID: String,
        disposition: ProjectHandbookRefreshDisposition,
        handbookPrefix: String
    ) -> ProjectHandbookRefreshResult {
        let snapshot = ProjectHandbookSnapshot(
            freshness: .current,
            reason: "Selected source snapshot matches",
            generation: "refresh-generation-\(projectID)",
            publishedGeneration: "refresh-generation-\(projectID)",
            path: "/tmp/\(projectID)/.byori/handbook.md",
            handbook: "\(handbookPrefix) for \(projectID)",
            isPreview: false,
            claimCount: 2,
            warnings: [],
            excludedSourceCount: 0,
            sensitiveSourceCount: 0,
            omittedSectionCount: 0,
            buildChanged: disposition == .rebuilt
        )
        return ProjectHandbookRefreshResult(
            disposition: disposition,
            freshness: .current,
            reason: snapshot.reason,
            generation: snapshot.generation,
            snapshot: snapshot,
            changed: disposition == .rebuilt
        )
    }
}

private func refreshConfiguration(
    for projectID: String,
    enabled: Bool = false,
    revision: String? = nil
) -> ProjectHandbookRefreshConfiguration {
    ProjectHandbookRefreshConfiguration(
        enabled: enabled,
        revision: revision,
        changeID: revision == nil ? nil : String(repeating: "d", count: 32),
        projectRoot: "/tmp/\(projectID)",
        checkoutID: String(repeating: projectID == "project-a" ? "a" : "b", count: 64),
        debounceMilliseconds: 300,
        sourceLimits: ProjectHandbookSourceLimits(
            maxCommits: 100,
            maxFiles: 60,
            maxFileBytes: 65_536,
            maxTotalBytes: 1_048_576,
            excludePaths: []
        ),
        maxCharacters: 12_000
    )
}

private func handbook(
    for projectID: String,
    freshness: ProjectHandbookFreshness = .current
) -> ProjectHandbookSnapshot {
    ProjectHandbookSnapshot(
        freshness: freshness,
        reason: freshness == .current ? "Selected source snapshot matches" : "Sources changed",
        generation: "generation-\(projectID)",
        publishedGeneration: freshness == .current ? "generation-\(projectID)" : "old-\(projectID)",
        path: "/tmp/\(projectID)/.byori/handbook.md",
        handbook: "Handbook for \(projectID)",
        isPreview: freshness != .current,
        claimCount: 2,
        warnings: [],
        excludedSourceCount: 0,
        sensitiveSourceCount: 0,
        omittedSectionCount: 0
    )
}
