import XCTest
@testable import ByoriManager

@MainActor
final class WorkspaceProjectCreationTests: XCTestCase {
    func testPlainFolderWaitsForConfirmationBeforeInitializingGit() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let dataSource = ProjectCreationDataSource(status: .requiresInitialization(folder))
        let model = WorkspaceViewModel(dataSource: dataSource)

        await model.addProjectFolder(at: folder)

        XCTAssertEqual(model.pendingProjectInitialization?.folderURL, folder)
        XCTAssertTrue(dataSource.registeredURLs.isEmpty)
        XCTAssertTrue(dataSource.initializedURLs.isEmpty)

        let request = try XCTUnwrap(model.pendingProjectInitialization)
        await model.initializePendingProject(request)

        XCTAssertNil(model.pendingProjectInitialization)
        XCTAssertEqual(dataSource.initializedURLs, [folder])
    }

    /// Confirming a dialog dismisses it, and dismissal clears the pending request
    /// synchronously while the button's `Task` body runs afterwards. A version that
    /// read the request back from the model therefore found nothing and returned
    /// without initializing, registering, or raising an alert: the folder was never
    /// added and the user was never told why.
    func testConfirmingStillInitializesWhenDismissalClearedThePendingRequestFirst() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let dataSource = ProjectCreationDataSource(status: .requiresInitialization(folder))
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.addProjectFolder(at: folder)
        let request = try XCTUnwrap(model.pendingProjectInitialization)

        // What the presentation binding does the moment the dialog closes.
        model.cancelProjectInitialization()
        XCTAssertNil(model.pendingProjectInitialization)

        await model.initializePendingProject(request)

        XCTAssertEqual(dataSource.initializedURLs, [folder])
    }

    func testGitFolderRegistersWithoutInitializationConfirmation() async {
        let repository = URL(fileURLWithPath: "/tmp/existing-repository", isDirectory: true)
        let dataSource = ProjectCreationDataSource(status: .gitRepository(repository))
        let model = WorkspaceViewModel(dataSource: dataSource)

        await model.addProjectFolder(at: repository)

        XCTAssertNil(model.pendingProjectInitialization)
        XCTAssertEqual(dataSource.registeredURLs, [repository])
        XCTAssertTrue(dataSource.initializedURLs.isEmpty)
    }

    func testNewProjectDraftRejectsExistingDestinationAndPassesTrimmedName() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-parent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let existing = parent.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let dataSource = ProjectCreationDataSource(status: .gitRepository(parent))
        let model = WorkspaceViewModel(dataSource: dataSource)
        model.presentNewProject()
        model.newProjectDraft.parentDirectoryURL = parent
        model.newProjectDraft.name = "Existing"

        XCTAssertFalse(model.canCreateProject)
        XCTAssertTrue(model.newProjectValidationMessage?.contains("already exists") == true)

        model.newProjectDraft.name = "  Fresh Project  "
        XCTAssertTrue(model.canCreateProject)
        await model.createProject()

        XCTAssertEqual(dataSource.createdProjects.count, 1)
        XCTAssertEqual(dataSource.createdProjects.first?.name, "Fresh Project")
        XCTAssertEqual(dataSource.createdProjects.first?.parent, parent)
        XCTAssertFalse(model.isPresentingNewProject)
    }
}

@MainActor
private final class ProjectCreationDataSource: WorkspaceDataSource {
    struct CreatedProject: Equatable {
        let name: String
        let parent: URL
    }

    let status: WorkspaceProjectFolderStatus
    var registeredURLs: [URL] = []
    var initializedURLs: [URL] = []
    var createdProjects: [CreatedProject] = []

    init(status: WorkspaceProjectFolderStatus) {
        self.status = status
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        WorkspacePresentationSnapshot(projects: [])
    }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] { [] }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        throw WorkspaceAdapterError.unsupported("Not used by project creation tests.")
    }

    func inspectProjectFolder(at folderURL: URL) async throws -> WorkspaceProjectFolderStatus {
        status
    }

    func registerProject(at repositoryURL: URL) async throws {
        registeredURLs.append(repositoryURL)
    }

    func initializeAndRegisterProject(at folderURL: URL) async throws {
        initializedURLs.append(folderURL)
    }

    func createProject(named name: String, in parentDirectoryURL: URL) async throws {
        createdProjects.append(CreatedProject(name: name, parent: parentDirectoryURL))
    }
}
