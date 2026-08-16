import XCTest
@testable import ByoriManagerCore

final class WorkspacePersistenceTests: XCTestCase {
    private var temporaryRoot: URL!
    private var byoriHome: URL!
    private var repositoryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        byoriHome = temporaryRoot.appendingPathComponent("home/.byori", isDirectory: true)
        repositoryRoot = temporaryRoot.appendingPathComponent("repositories/current", isDirectory: true)
        try FileManager.default.createDirectory(at: byoriHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testSchemaV1ProjectsLoadAdditivelyAsSourceTrees() async throws {
        let addedAt = "2026-08-06T01:02:03Z"
        try writeJSONObject([
            "schema_version": 1,
            "extension": ["keep": true],
            "projects": [[
                "id": "abc123def456",
                "name": "goosefish",
                "root": repositoryRoot.path,
                "space": "byori_goosefish_abc123",
                "remote": "https://example.test/getpaseo/byori.git",
                "added_at": addedAt,
                "unknown_project_key": "preserve-on-write",
            ]],
        ], to: byoriHome.appendingPathComponent("projects.json"))

        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(root: repositoryRoot)
        )
        let projects = try await registry.projects()

        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project.id, "abc123def456")
        XCTAssertEqual(project.rootPath, repositoryRoot.path)
        XCTAssertEqual(project.sourceTrees, [
            WorkspaceSourceTree(
                id: "source-abc123def456",
                projectID: "abc123def456",
                path: repositoryRoot.path
            ),
        ])
    }

    func testPreviewIsExplicitNonPersistedAndOnlyAvailableForEmptyRegistry() async throws {
        let registryURL = byoriHome.appendingPathComponent("projects.json")
        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(
                root: repositoryRoot,
                remote: "https://oauth:secret-token@example.test/org/repo.git?access_token=secret#private"
            ),
            idGenerator: { "preview12345" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let preview = try await registry.previewUnregisteredProject(at: repositoryRoot)
        XCTAssertEqual(preview?.rootPath, repositoryRoot.path)
        XCTAssertEqual(preview?.remote, "https://example.test/org/repo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryURL.path))

        let registered = try await registry.registerProject(at: repositoryRoot, memorySpace: nil)
        XCTAssertEqual(registered.id, "preview12345")
        XCTAssertEqual(registered.remote, "https://example.test/org/repo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: registryURL.path))
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        let rawProjects = try XCTUnwrap(raw["projects"] as? [[String: Any]])
        XCTAssertEqual(rawProjects.first?["remote"] as? String, "https://example.test/org/repo")
        let previewAfterRegistration = try await registry.previewUnregisteredProject(at: repositoryRoot)
        XCTAssertNil(previewAfterRegistration)
    }

    func testPreviewRemovesScpStyleRemoteUserInfo() async throws {
        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(
                root: repositoryRoot,
                remote: "oauth:secret-token@example.test:org/repo.git"
            )
        )

        let preview = try await registry.previewUnregisteredProject(at: repositoryRoot)

        XCTAssertEqual(preview?.remote, "example.test:org/repo")
    }

    func testRegistrationPreservesUnknownSchemaV1JSONAndUsesPrivateAtomicFile() async throws {
        let existingRoot = temporaryRoot.appendingPathComponent("repositories/existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingRoot, withIntermediateDirectories: true)
        let registryURL = byoriHome.appendingPathComponent("projects.json")
        try writeJSONObject([
            "schema_version": 1,
            "extension": ["keep": true],
            "projects": [[
                "id": "existing1234",
                "name": "existing",
                "root": existingRoot.path,
                "space": "byori_existing_1234",
                "remote": "",
                "added_at": "2026-08-06T01:02:03Z",
                "unknown_project_key": "keep",
            ]],
        ], to: registryURL)

        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(root: repositoryRoot),
            idGenerator: { "newproject12" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        _ = try await registry.registerProject(at: repositoryRoot, memorySpace: "byori_new_project")

        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        XCTAssertEqual((raw["extension"] as? [String: Any])?["keep"] as? Bool, true)
        let rawProjects = try XCTUnwrap(raw["projects"] as? [[String: Any]])
        XCTAssertEqual(rawProjects.count, 2)
        XCTAssertEqual(rawProjects[0]["unknown_project_key"] as? String, "keep")
        XCTAssertEqual(rawProjects[1]["id"] as? String, "newproject12")
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: registryURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: byoriHome.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testProjectRemovalArchivesExactRecordAndRegistrationRestoresIdentityAndHistory() async throws {
        let registryURL = byoriHome.appendingPathComponent("projects.json")
        let taskSentinel = byoriHome.appendingPathComponent("tasks/task-history/state.json")
        let databaseSentinel = byoriHome.appendingPathComponent("database/space.data")
        let repositorySentinel = repositoryRoot.appendingPathComponent("uncommitted-user-work.txt")
        try FileManager.default.createDirectory(
            at: taskSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: databaseSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("task-history".utf8).write(to: taskSentinel)
        try Data("database-history".utf8).write(to: databaseSentinel)
        try Data("repository-work".utf8).write(to: repositorySentinel)

        let originalProject: [String: Any] = [
            "id": "archive12345",
            "name": "current",
            "root": repositoryRoot.path,
            "space": "byori_current_archive",
            "remote": "https://example.test/org/current",
            "added_at": "2026-08-06T01:02:03Z",
            "unknown_project_key": ["keep": true],
            "source_trees": [[
                "id": "source-archive12345",
                "path": repositoryRoot.path,
                "unknown_source_key": "keep-source",
            ]],
        ]
        try writeJSONObject([
            "schema_version": 1,
            "unknown_root_key": ["keep": true],
            "projects": [originalProject],
            "removed_projects": [[String: Any]](),
        ], to: registryURL)

        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(root: repositoryRoot),
            idGenerator: { "mustnotreplace" }
        )
        let removed = try await registry.removeProject(id: "archive12345")

        XCTAssertEqual(removed.id, "archive12345")
        let projectsAfterRemoval = try await registry.projects()
        XCTAssertTrue(projectsAfterRemoval.isEmpty)
        var raw = try readJSONObject(at: registryURL)
        XCTAssertEqual((raw["projects"] as? [[String: Any]])?.count, 0)
        let archived = try XCTUnwrap((raw["removed_projects"] as? [[String: Any]])?.first)
        XCTAssertTrue(NSDictionary(dictionary: archived).isEqual(to: originalProject))
        XCTAssertEqual((raw["unknown_root_key"] as? [String: Any])?["keep"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: repositorySentinel), Data("repository-work".utf8))
        XCTAssertEqual(try Data(contentsOf: taskSentinel), Data("task-history".utf8))
        XCTAssertEqual(try Data(contentsOf: databaseSentinel), Data("database-history".utf8))

        let restored = try await registry.registerProject(at: repositoryRoot, memorySpace: nil)

        XCTAssertEqual(restored.id, "archive12345")
        XCTAssertEqual(restored.memorySpace, "byori_current_archive")
        raw = try readJSONObject(at: registryURL)
        let restoredRaw = try XCTUnwrap((raw["projects"] as? [[String: Any]])?.first)
        XCTAssertTrue(NSDictionary(dictionary: restoredRaw).isEqual(to: originalProject))
        XCTAssertEqual((raw["removed_projects"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(try Data(contentsOf: repositorySentinel), Data("repository-work".utf8))
        XCTAssertEqual(try Data(contentsOf: taskSentinel), Data("task-history".utf8))
        XCTAssertEqual(try Data(contentsOf: databaseSentinel), Data("database-history".utf8))
    }

    /// The same vectors are asserted in Python (tests/test_memory_space.py). A
    /// change on one side that is not mirrored on the other splits a project's
    /// memory across two spaces, which is what deriving the name prevents.
    func testDerivedMemorySpaceMatchesTheCrossLanguageVectors() {
        let vectors: [(String, String)] = [
            ("/Users/teo/byori", "byori_byori_89107dac"),
            ("/Users/teo/My Project!", "byori_my_project_c7270d6a"),
            // A slug that does not start with a letter takes the `p_` prefix.
            ("/Users/teo/2048", "byori_p_2048_5123ef0f"),
            // Nothing ASCII-alphanumeric survives, so the slug falls back.
            ("/Users/teo/프로젝트", "byori_project_3d2e3680"),
            // Cut to 36 characters, then any trailing underscore removed.
            (
                "/Users/teo/" + String(repeating: "a", count: 35) + "-b",
                "byori_" + String(repeating: "a", count: 35) + "_31597749"
            ),
            ("/", "byori_project_8a5edab2"),
            ("/tmp/repo.git", "byori_repo_git_148929e4"),
        ]
        for (rootPath, expected) in vectors {
            XCTAssertEqual(
                WorkspaceProjectRegistry.defaultMemorySpace(rootPath: rootPath),
                expected,
                "derived space for \(rootPath)"
            )
        }
    }

    func testRegistrationDerivesTheMemorySpaceFromTheRootPath() async throws {
        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(root: repositoryRoot),
            idGenerator: { "derived12345" }
        )
        let project = try await registry.registerProject(at: repositoryRoot, memorySpace: nil)

        let canonicalRoot = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(project.rootPath, canonicalRoot)
        XCTAssertEqual(
            project.memorySpace,
            WorkspaceProjectRegistry.defaultMemorySpace(rootPath: canonicalRoot)
        )
        // The name must not depend on the project id, or nothing could recompute it.
        XCTAssertFalse(project.memorySpace.contains("derived12345"))
    }

    func testRegistrationRefusesAMemorySpaceAnotherProjectAlreadyUses() async throws {
        let registryURL = byoriHome.appendingPathComponent("projects.json")
        let otherRoot = temporaryRoot.appendingPathComponent("repositories/other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let canonicalRoot = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let collidingSpace = WorkspaceProjectRegistry.defaultMemorySpace(rootPath: canonicalRoot)
        try writeJSONObject([
            "schema_version": 1,
            "projects": [[
                "id": "collision123",
                "name": "other",
                "root": otherRoot.path,
                "space": collidingSpace,
                "remote": "",
                "added_at": "2026-08-06T01:02:03Z",
            ]],
        ], to: registryURL)
        let unchanged = try Data(contentsOf: registryURL)

        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(root: repositoryRoot)
        )
        do {
            _ = try await registry.registerProject(at: repositoryRoot, memorySpace: nil)
            XCTFail("A memory space shared with another project must fail closed")
        } catch let error as WorkspaceError {
            guard case .invalidProject = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), unchanged)
    }

    func testProjectMutationsFailClosedForDuplicateIdentityMissingProjectAndSchema() async throws {
        let registryURL = byoriHome.appendingPathComponent("projects.json")
        let otherRoot = temporaryRoot.appendingPathComponent("repositories/other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let duplicateDocument: [String: Any] = [
            "schema_version": 1,
            "projects": [[
                "id": "duplicate123",
                "name": "current",
                "root": repositoryRoot.path,
                "space": "byori_current_duplicate",
                "remote": "",
                "added_at": "2026-08-06T01:02:03Z",
            ]],
            "removed_projects": [[
                "id": "duplicate123",
                "name": "other",
                "root": otherRoot.path,
                "space": "byori_other_duplicate",
                "remote": "",
                "added_at": "2026-08-06T01:02:04Z",
            ]],
        ]
        try writeJSONObject(duplicateDocument, to: registryURL)
        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(root: repositoryRoot)
        )
        let duplicateBytes = try Data(contentsOf: registryURL)

        do {
            _ = try await registry.removeProject(id: "duplicate123")
            XCTFail("Duplicate project identity must fail closed")
        } catch let error as WorkspaceError {
            guard case .invalidRegistry = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), duplicateBytes)

        try writeJSONObject([
            "schema_version": 1,
            "projects": [[
                "id": "present12345",
                "name": "current",
                "root": repositoryRoot.path,
                "space": "byori_current_present",
                "remote": "",
                "added_at": "2026-08-06T01:02:03Z",
            ]],
        ], to: registryURL)
        let missingBytes = try Data(contentsOf: registryURL)
        do {
            _ = try await registry.removeProject(id: "missing12345")
            XCTFail("Missing project removal must fail")
        } catch let error as WorkspaceError {
            XCTAssertEqual(error, .projectNotFound("missing12345"))
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), missingBytes)

        try writeJSONObject([
            "schema_version": 99,
            "projects": [[String: Any]](),
            "unknown_root_key": "keep",
        ], to: registryURL)
        let unsupportedBytes = try Data(contentsOf: registryURL)
        do {
            _ = try await registry.registerProject(at: repositoryRoot, memorySpace: nil)
            XCTFail("Unsupported project schema must fail closed")
        } catch let error as WorkspaceError {
            XCTAssertEqual(error, .unsupportedProjectSchema(99))
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), unsupportedBytes)
    }

    func testTaskStorePersistsOnlyMetadataAndKeepsSessionIdentityImmutable() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = WorkspaceTaskStore(home: byoriHome, now: { fixedDate })
        let task = try await store.createTask(
            projectID: "project123",
            checkout: WorkspaceCheckoutReference(kind: .worktree, id: "worktree123"),
            title: "Implement the workspace shell"
        )
        let first = try await store.createSession(
            taskID: task.id,
            name: "Quiet Harbor",
            provider: .claude,
            model: "claude-sonnet"
        )

        do {
            _ = try await store.createSession(
                taskID: task.id,
                provider: .codex,
                model: "gpt-5-codex"
            )
            XCTFail("A second session must not start while one is open")
        } catch let error as WorkspaceError {
            XCTAssertEqual(error, .openSessionExists(task.id))
        }

        let active = try await store.updateSessionStatus(
            taskID: task.id,
            sessionID: first.id,
            status: .active,
            nativeSessionID: "native-claude-session"
        )
        XCTAssertEqual(active.provider, .claude)
        XCTAssertEqual(active.model, "claude-sonnet")
        XCTAssertEqual(active.name, "Quiet Harbor")
        XCTAssertEqual(active.nativeSessionID, "native-claude-session")

        let completed = try await store.updateSessionStatus(
            taskID: task.id,
            sessionID: first.id,
            status: .completed,
            nativeSessionID: nil
        )
        XCTAssertEqual(completed.provider, .claude)
        XCTAssertEqual(completed.model, "claude-sonnet")
        XCTAssertEqual(completed.name, "Quiet Harbor")

        let second = try await store.createSession(
            taskID: task.id,
            provider: .codex,
            model: "gpt-5-codex"
        )
        XCTAssertNotEqual(first.id, second.id)

        let taskDirectory = byoriHome.appendingPathComponent("tasks/\(task.id)", isDirectory: true)
        // These files deliberately contain non-JSON bytes. Metadata reads must use
        // only the exact state.json path and must not inspect prompt or log bodies.
        try Data([0xff, 0x00, 0xfe]).write(to: taskDirectory.appendingPathComponent("prompt.txt"))
        try Data([0x00, 0xff]).write(to: taskDirectory.appendingPathComponent("session.stdout.jsonl"))

        let loaded = try await store.task(id: task.id)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.sessions.count, 2)
        XCTAssertEqual(reloaded.sessions[0].provider, .claude)
        XCTAssertEqual(reloaded.sessions[0].model, "claude-sonnet")
        XCTAssertEqual(reloaded.sessions[0].name, "Quiet Harbor")
        XCTAssertEqual(reloaded.sessions[1].provider, .codex)
        XCTAssertEqual(reloaded.sessions[1].model, "gpt-5-codex")
        XCTAssertNil(reloaded.sessions[1].name)

        let rawState = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: taskDirectory.appendingPathComponent("state.json"))
            ) as? [String: Any]
        )
        let rawTask = try XCTUnwrap(rawState["task"] as? [String: Any])
        let rawSessions = try XCTUnwrap(rawTask["sessions"] as? [[String: Any]])
        XCTAssertEqual(rawSessions[0]["display_name"] as? String, "Quiet Harbor")
        XCTAssertNil(rawSessions[1]["display_name"])
    }

    func testSessionNameValidationIsTrimmedNonemptyAndBounded() async throws {
        let store = WorkspaceTaskStore(home: byoriHome)
        let task = try await store.createTask(
            projectID: "project123",
            checkout: WorkspaceCheckoutReference(kind: .sourceTree, id: "source123"),
            title: "Validate session names"
        )

        for invalidName in [
            "",
            "   ",
            " Quiet Harbor ",
            "Quiet\nHarbor",
            String(repeating: "a", count: WorkspaceSession.maximumNameScalarCount + 1),
        ] {
            do {
                _ = try await store.createSession(
                    taskID: task.id,
                    name: invalidName,
                    provider: .claude,
                    model: "claude-sonnet"
                )
                XCTFail("Invalid session name unexpectedly persisted: \(invalidName)")
            } catch let error as WorkspaceError {
                XCTAssertEqual(error, .invalidSessionName)
            }
        }

        let unicodeName = String(repeating: "별", count: WorkspaceSession.maximumNameScalarCount)
        let session = try await store.createSession(
            taskID: task.id,
            name: unicodeName,
            provider: .claude,
            model: "claude-sonnet"
        )
        XCTAssertEqual(session.name, unicodeName)
    }

    func testSchemaV1SessionWithoutDisplayNameRemainsReadable() async throws {
        let taskID = "legacytask123"
        let stateURL = byoriHome.appendingPathComponent("tasks/\(taskID)/state.json")
        try writeJSONObject([
            "schema_version": 1,
            "task": [
                "id": taskID,
                "project_id": "project123",
                "checkout": ["kind": "source_tree", "id": "source123"],
                "title": "Read legacy session metadata",
                "status": "active",
                "sessions": [[
                    "id": "legacysession123",
                    "provider": "codex",
                    "model": "gpt-5-codex",
                    "status": "active",
                    "created_at": "2026-08-06T01:02:03Z",
                    "started_at": "2026-08-06T01:02:04Z",
                ]],
                "created_at": "2026-08-06T01:02:03Z",
                "updated_at": "2026-08-06T01:02:04Z",
            ],
        ], to: stateURL)

        let store = WorkspaceTaskStore(home: byoriHome)
        let loadedLegacyTask = try await store.task(id: taskID)
        let legacyTask = try XCTUnwrap(loadedLegacyTask)
        XCTAssertNil(legacyTask.sessions.first?.name)
        XCTAssertEqual(legacyTask.sessions.first?.provider, .codex)
        XCTAssertEqual(legacyTask.sessions.first?.model, "gpt-5-codex")
    }

    func testTaskListingIsBounded() async throws {
        let store = WorkspaceTaskStore(home: byoriHome)
        for index in 0..<3 {
            _ = try await store.createTask(
                projectID: "project123",
                checkout: WorkspaceCheckoutReference(kind: .sourceTree, id: "source123"),
                title: "Task \(index)"
            )
        }

        let list = try await store.tasks(projectID: "project123", limit: 2)
        XCTAssertEqual(list.tasks.count, 2)
        XCTAssertTrue(list.isTruncated)
    }

    func testArchivingTaskPreservesMetadataAndRemovesItFromActiveReads() async throws {
        let store = WorkspaceTaskStore(home: byoriHome)
        let task = try await store.createTask(
            projectID: "project123",
            checkout: WorkspaceCheckoutReference(kind: .worktree, id: "worktree123"),
            title: "Archive completed work"
        )
        let session = try await store.createSession(
            taskID: task.id,
            provider: .claude,
            model: "claude-sonnet"
        )
        let taskDirectory = byoriHome.appendingPathComponent("tasks/\(task.id)", isDirectory: true)
        let evidence = taskDirectory.appendingPathComponent("session-summary.txt")
        try Data("kept".utf8).write(to: evidence)

        do {
            _ = try await store.archiveTask(id: task.id)
            XCTFail("A task with an open session must not be archived")
        } catch let error as WorkspaceError {
            guard case .invalidTask = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        _ = try await store.updateSessionStatus(
            taskID: task.id,
            sessionID: session.id,
            status: .cancelled
        )
        let archived = try await store.archiveTask(id: task.id)
        let activeTask = try await store.task(id: task.id)
        let activeTasks = try await store.tasks(projectID: "project123", limit: 20)

        XCTAssertEqual(archived.id, task.id)
        XCTAssertNil(activeTask)
        XCTAssertTrue(activeTasks.tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: taskDirectory.path))
        let archivedEvidence = byoriHome
            .appendingPathComponent("archived-tasks/\(task.id)/session-summary.txt")
        XCTAssertEqual(try Data(contentsOf: archivedEvidence), Data("kept".utf8))
    }

    func testProjectReadsDiscoverAllGitWorktreesWithStableIDsWithoutRegistryMutation() async throws {
        let linked = temporaryRoot.appendingPathComponent("repositories/linked", isDirectory: true)
        let managed = byoriHome.appendingPathComponent("worktrees/run/worker", isDirectory: true)
        let registryURL = byoriHome.appendingPathComponent("projects.json")
        try writeJSONObject([
            "schema_version": 1,
            "projects": [[
                "id": "project12345",
                "name": "current",
                "root": repositoryRoot.path,
                "space": "byori_current_1234",
                "remote": "",
                "added_at": "2026-08-06T01:02:03Z",
            ]],
        ], to: registryURL)
        let snapshots = [
            WorkspaceGitWorktreeSnapshot(
                path: repositoryRoot.path,
                branch: "main",
                headRevision: String(repeating: "a", count: 40),
                isPrimary: true
            ),
            WorkspaceGitWorktreeSnapshot(
                path: linked.path,
                branch: "feature/linked",
                headRevision: String(repeating: "b", count: 40),
                isPrimary: false
            ),
            WorkspaceGitWorktreeSnapshot(
                path: managed.path,
                branch: "byori/run/worker",
                headRevision: String(repeating: "c", count: 40),
                isPrimary: false
            ),
        ]
        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(root: repositoryRoot, worktreeSnapshots: snapshots)
        )

        let firstProjects = try await registry.projects()
        let secondProjects = try await registry.projects()
        let first = try XCTUnwrap(firstProjects.first)
        let second = try XCTUnwrap(secondProjects.first)
        let firstWorktrees = try XCTUnwrap(first.sourceTrees.first).worktrees
        let secondWorktrees = try XCTUnwrap(second.sourceTrees.first).worktrees

        XCTAssertEqual(firstWorktrees.map(\.path), [linked.path, managed.path])
        XCTAssertEqual(firstWorktrees.map(\.branch), ["feature/linked", "byori/run/worker"])
        XCTAssertEqual(firstWorktrees.map(\.id), secondWorktrees.map(\.id))
        XCTAssertTrue(firstWorktrees.allSatisfy { $0.id.hasPrefix("worktree-project12345-") })
        XCTAssertFalse(firstWorktrees[0].isManaged)
        XCTAssertTrue(firstWorktrees[1].isManaged)

        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        let rawProjects = try XCTUnwrap(raw["projects"] as? [[String: Any]])
        XCTAssertNil(rawProjects.first?["source_trees"])
    }

    func testCheckoutVisibilityIsCanonicalPrivateProjectScopedAndIdempotent() async throws {
        let checkout = temporaryRoot.appendingPathComponent("repositories/linked", isDirectory: true)
        let symlink = temporaryRoot.appendingPathComponent("linked-symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: checkout)
        let store = WorkspaceCheckoutVisibilityStore(home: byoriHome)

        try await store.hideCheckout(projectID: "projectalpha", at: symlink)
        try await store.hideCheckout(projectID: "projectalpha", at: symlink)
        try await store.hideCheckout(projectID: "projectbeta", at: checkout)

        let expectedPath = checkout.resolvingSymlinksInPath().standardizedFileURL.path
        let hiddenAlpha = try await store.hiddenCheckoutPaths(projectID: "projectalpha")
        let hiddenBeta = try await store.hiddenCheckoutPaths(projectID: "projectbeta")
        XCTAssertEqual(hiddenAlpha, Set([expectedPath]))
        XCTAssertEqual(hiddenBeta, Set([expectedPath]))
        let stateURL = byoriHome.appendingPathComponent("manager/checkout-visibility.json")
        let raw = try readJSONObject(at: stateURL)
        XCTAssertEqual((raw["hidden_checkouts"] as? [[String: Any]])?.count, 2)
        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions] as? NSNumber
        )
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: stateURL.deletingLastPathComponent().path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)

        let reloaded = WorkspaceCheckoutVisibilityStore(home: byoriHome)
        try await reloaded.unhideCheckout(projectID: "projectalpha", at: checkout)
        let reloadedAlpha = try await reloaded.hiddenCheckoutPaths(projectID: "projectalpha")
        let reloadedBeta = try await reloaded.hiddenCheckoutPaths(projectID: "projectbeta")
        XCTAssertTrue(reloadedAlpha.isEmpty)
        XCTAssertEqual(reloadedBeta, Set([expectedPath]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.path))
    }

    func testHiddenDiscoveredCheckoutDoesNotReappearAcrossRegistryRefresh() async throws {
        let linked = temporaryRoot.appendingPathComponent("repositories/linked", isDirectory: true)
        let managed = byoriHome.appendingPathComponent("worktrees/run/worker", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let registryURL = byoriHome.appendingPathComponent("projects.json")
        try writeJSONObject([
            "schema_version": 1,
            "projects": [[
                "id": "visibility123",
                "name": "current",
                "root": repositoryRoot.path,
                "space": "byori_current_visibility",
                "remote": "",
                "added_at": "2026-08-06T01:02:03Z",
            ]],
        ], to: registryURL)
        let snapshots = [
            WorkspaceGitWorktreeSnapshot(
                path: repositoryRoot.path,
                branch: "main",
                headRevision: String(repeating: "a", count: 40),
                isPrimary: true
            ),
            WorkspaceGitWorktreeSnapshot(
                path: linked.path,
                branch: "feature/linked",
                headRevision: String(repeating: "b", count: 40),
                isPrimary: false
            ),
            WorkspaceGitWorktreeSnapshot(
                path: managed.path,
                branch: "byori/run/worker",
                headRevision: String(repeating: "c", count: 40),
                isPrimary: false
            ),
        ]
        let visibility = WorkspaceCheckoutVisibilityStore(home: byoriHome)
        try await visibility.hideCheckout(projectID: "visibility123", at: linked)
        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(root: repositoryRoot, worktreeSnapshots: snapshots),
            visibilityStore: visibility
        )

        let first = try await registry.projects()
        let second = try await registry.projects()

        XCTAssertEqual(first.first?.sourceTrees.first?.worktrees.map(\.path), [managed.path])
        XCTAssertEqual(second.first?.sourceTrees.first?.worktrees.map(\.path), [managed.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))

        try await visibility.unhideCheckout(projectID: "visibility123", at: linked)
        let restored = try await registry.projects()
        XCTAssertEqual(restored.first?.sourceTrees.first?.worktrees.map(\.path), [linked.path, managed.path])
    }

    func testCheckoutVisibilityRejectsDuplicateAndOversizedMetadataWithoutMutation() async throws {
        let checkout = temporaryRoot.appendingPathComponent("repositories/linked", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let stateURL = byoriHome.appendingPathComponent("manager/checkout-visibility.json")
        let duplicatedEntry: [String: Any] = [
            "project_id": "projectalpha",
            "path": checkout.path,
        ]
        try writeJSONObject([
            "schema_version": 1,
            "hidden_checkouts": [duplicatedEntry, duplicatedEntry],
        ], to: stateURL)
        let duplicateBytes = try Data(contentsOf: stateURL)
        let store = WorkspaceCheckoutVisibilityStore(home: byoriHome)

        do {
            try await store.hideCheckout(projectID: "projectalpha", at: repositoryRoot)
            XCTFail("Duplicate visibility entries must fail closed")
        } catch let error as WorkspaceError {
            guard case .invalidRegistry = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), duplicateBytes)

        try writeJSONObject([
            "schema_version": 1,
            "hidden_checkouts": [[
                "project_id": "projectalpha",
                "path": "/" + String(repeating: "a", count: 4_096),
            ]],
        ], to: stateURL)
        do {
            _ = try await store.hiddenCheckoutPaths(projectID: "projectalpha")
            XCTFail("Oversized checkout paths must be rejected")
        } catch let error as WorkspaceError {
            guard case .invalidRegistry = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExplicitNonGitProjectKeepsDecodedSourceTreeWhenDiscoveryFails() async throws {
        try writeJSONObject([
            "schema_version": 1,
            "projects": [[
                "id": "nongit123456",
                "name": "notes",
                "root": repositoryRoot.path,
                "space": "byori_notes_1234",
                "remote": "",
                "added_at": "2026-08-06T01:02:03Z",
                "source_trees": [[
                    "id": "source-nongit123456",
                    "path": repositoryRoot.path,
                    "worktrees": [[
                        "id": "manual-checkout",
                        "path": temporaryRoot.appendingPathComponent("manual-checkout").path,
                        "branch": "manual",
                        "managed": false,
                    ]],
                ]],
            ]],
        ], to: byoriHome.appendingPathComponent("projects.json"))
        let registry = WorkspaceProjectRegistry(
            home: byoriHome,
            git: StubWorkspaceGit(
                root: repositoryRoot,
                worktreeError: .notGitRepository(repositoryRoot.path)
            )
        )

        let projects = try await registry.projects()
        let project = try XCTUnwrap(projects.first)

        XCTAssertEqual(project.sourceTrees.first?.id, "source-nongit123456")
        XCTAssertEqual(project.sourceTrees.first?.worktrees.first?.id, "manual-checkout")
    }

    private func writeJSONObject(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            .write(to: url)
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }
}

private struct StubWorkspaceGit: WorkspaceGitInspecting {
    let root: URL
    var remote: String? = nil
    var worktreeSnapshots: [WorkspaceGitWorktreeSnapshot] = []
    var worktreeError: WorkspaceError? = nil

    func repositoryRoot(at path: URL) async throws -> URL {
        root
    }

    func originRemote(at repositoryRoot: URL) async throws -> String? {
        remote
    }

    func worktrees(at path: URL) async throws -> [WorkspaceGitWorktreeSnapshot] {
        if let worktreeError { throw worktreeError }
        return worktreeSnapshots
    }

    func status(at path: URL, maxChanges: Int) async throws -> WorkspaceGitStatusSnapshot {
        WorkspaceGitStatusSnapshot(
            repositoryRoot: root.path,
            branch: "main",
            headRevision: nil,
            changes: [],
            isTruncated: false
        )
    }
}
