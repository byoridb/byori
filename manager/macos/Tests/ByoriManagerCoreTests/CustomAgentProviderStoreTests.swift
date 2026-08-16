import XCTest
@testable import ByoriManagerCore

/// A registered CLI is launched with the exact executable and argv recorded here,
/// and its id is written into stored sessions. So the two things worth pinning are
/// what the store refuses to accept, and that a custom id can never be mistaken
/// for a built-in provider.
final class CustomAgentProviderStoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var paths: ManagerPaths!
    private var store: CustomAgentProviderStore!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-custom-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        paths = ManagerPaths(home: temporaryRoot, runtimeRoot: temporaryRoot)
        store = CustomAgentProviderStore(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testRegisteredCLISurvivesANewStoreInstance() async throws {
        let executable = try makeExecutable(named: "my-cli")

        let added = try await store.add(
            displayName: "My CLI",
            executablePath: executable.path,
            defaultArguments: ["--yes", "--profile", "work"]
        )
        XCTAssertEqual(added.displayName, "My CLI")
        XCTAssertEqual(added.executablePath, executable.resolvingSymlinksInPath().path)
        XCTAssertEqual(added.defaultArguments, ["--yes", "--profile", "work"])

        // A second store must read the same file rather than its own memory: the
        // workspace and Settings each hold one.
        let reopened = await CustomAgentProviderStore(paths: paths).providers()
        XCTAssertEqual(reopened, [added])
    }

    /// The id lands in persisted sessions next to built-in provider ids, so a
    /// custom CLI named after one must not be able to shadow it.
    func testCustomIdentifiersCannotCollideWithABuiltInProvider() async throws {
        let executable = try makeExecutable(named: "claude-lookalike")

        let added = try await store.add(displayName: "Claude", executablePath: executable.path)

        XCTAssertEqual(added.id, "custom-claude")
        XCTAssertNil(
            AgentKind(rawValue: added.id),
            "a custom id must never parse as a built-in provider"
        )
        for kind in AgentKind.allCases {
            XCTAssertNotEqual(added.id, kind.rawValue)
        }
    }

    func testTwoNamesThatSlugifyTheSameAreRefused() async throws {
        let executable = try makeExecutable(named: "dup")
        _ = try await store.add(displayName: "My CLI", executablePath: executable.path)

        do {
            _ = try await store.add(displayName: "my  cli", executablePath: executable.path)
            XCTFail("a colliding identifier must not be registered twice")
        } catch let error as CustomAgentProviderError {
            guard case .duplicateName = error else {
                return XCTFail("expected a duplicate-name error, got \(error)")
            }
        }
        let providers = await store.providers()
        XCTAssertEqual(providers.count, 1)
    }

    /// Byori launches this path directly. Accepting something that is not an
    /// executable file would turn a Settings mistake into a failed session later.
    func testOnlyARealExecutableFileIsAccepted() async throws {
        let notExecutable = temporaryRoot.appendingPathComponent("plain.txt")
        try Data("hello".utf8).write(to: notExecutable)

        for candidate in [notExecutable.path, temporaryRoot.path, "relative/cli", "/does/not/exist"] {
            do {
                _ = try await store.add(displayName: "Candidate", executablePath: candidate)
                XCTFail("accepted a non-executable path: \(candidate)")
            } catch let error as CustomAgentProviderError {
                guard case .invalidExecutable = error else {
                    return XCTFail("expected an invalid-executable error for \(candidate), got \(error)")
                }
            }
        }
    }

    func testNameIsTrimmedAndBounded() async throws {
        let executable = try makeExecutable(named: "bounded")

        let trimmed = try await store.add(displayName: "  Spaced  ", executablePath: executable.path)
        XCTAssertEqual(trimmed.displayName, "Spaced")

        for invalid in ["", "   ", "line\nbreak",
                        String(repeating: "x", count: CustomAgentProvider.maximumNameLength + 1)] {
            do {
                _ = try await store.add(displayName: invalid, executablePath: executable.path)
                XCTFail("accepted an invalid name: \(invalid.debugDescription)")
            } catch let error as CustomAgentProviderError {
                XCTAssertEqual(error, .invalidName)
            }
        }
    }

    /// A newline would make the recorded launch unreadable, and a NUL would
    /// truncate the argument that `execve` actually receives.
    func testArgumentsAreValidatedAndBounded() async throws {
        let executable = try makeExecutable(named: "args")

        do {
            _ = try await store.add(
                displayName: "Newline",
                executablePath: executable.path,
                defaultArguments: ["--flag\n--smuggled"]
            )
            XCTFail("accepted an argument containing a newline")
        } catch let error as CustomAgentProviderError {
            XCTAssertEqual(error, .invalidArgument)
        }

        do {
            _ = try await store.add(
                displayName: "Too many",
                executablePath: executable.path,
                defaultArguments: Array(
                    repeating: "--flag",
                    count: CustomAgentProvider.maximumArguments + 1
                )
            )
            XCTFail("accepted more arguments than the documented limit")
        } catch let error as CustomAgentProviderError {
            XCTAssertEqual(error, .tooManyArguments)
        }
    }

    func testRemovingAnUnknownIdentifierReportsItRatherThanSucceeding() async throws {
        do {
            try await store.remove(id: "custom-missing")
            XCTFail("removing an unregistered CLI must not report success")
        } catch let error as CustomAgentProviderError {
            XCTAssertEqual(error, .notFound("custom-missing"))
        }
    }

    func testRemoveLeavesTheOtherRegistrations() async throws {
        let first = try await store.add(
            displayName: "First",
            executablePath: try makeExecutable(named: "first").path
        )
        let second = try await store.add(
            displayName: "Second",
            executablePath: try makeExecutable(named: "second").path
        )

        try await store.remove(id: first.id)

        let providers = await store.providers()
        XCTAssertEqual(providers, [second])
    }

    /// A list that cannot be parsed must not stop the app from launching the CLIs
    /// it does know about, so the read degrades to empty instead of throwing.
    func testDamagedFileReadsAsEmptyRatherThanFailing() async throws {
        let file = paths.managerHome.appendingPathComponent("custom-agents.json")
        try FileManager.default.createDirectory(
            at: paths.managerHome,
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: file)

        let providers = await store.providers()
        XCTAssertTrue(providers.isEmpty)

        // And a later registration recovers the file rather than inheriting the damage.
        let added = try await store.add(
            displayName: "Recovered",
            executablePath: try makeExecutable(named: "recovered").path
        )
        let reread = await store.providers()
        XCTAssertEqual(reread, [added])
    }

    @discardableResult
    private func makeExecutable(named name: String) throws -> URL {
        let file = temporaryRoot.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.path
        )
        return file
    }
}
