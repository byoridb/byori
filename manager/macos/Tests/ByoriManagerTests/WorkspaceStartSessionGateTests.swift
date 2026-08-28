import ByoriManagerCore
import XCTest
@testable import ByoriManager

/// A disabled Start Session must always be able to say why.
///
/// The button used to refuse in silence: `canStartSession` was a bare Bool and the
/// only sentence naming an unmet requirement lived behind a guard the disabled
/// button made unreachable. The requirement most often unmet — no provider chosen
/// — is also the furthest down the form, so on a short window the sheet looked
/// complete and the button simply did not work.
@MainActor
final class WorkspaceStartSessionGateTests: XCTestCase {
    /// The whole ladder, in the order the sheet reads. Every rung has to name the
    /// next thing to do, and the button stays locked in lockstep with the reason.
    func testEachMissingRequirementIsNamedUntilTheButtonUnlocks() async {
        let dataSource = GateDataSource()
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.prepareNewSession()

        XCTAssertEqual(model.startSessionBlockedReason, "Give the new task a title.")
        XCTAssertFalse(model.canStartSession)

        model.newSessionDraft.newTaskTitle = "Fix the parser"
        XCTAssertEqual(model.startSessionBlockedReason, "Choose the launch provider under Agent.")
        XCTAssertFalse(model.canStartSession)

        model.chooseProvider("claude")
        XCTAssertEqual(model.startSessionBlockedReason, "Choose the model under Agent.")
        XCTAssertFalse(model.canStartSession)

        model.chooseModel("default")
        XCTAssertNil(model.startSessionBlockedReason)
        XCTAssertTrue(model.canStartSession)
    }

    /// Choosing a provider clears the model, so the sheet must ask for the model
    /// again rather than leaving the button dead with nothing to read.
    func testSwitchingProviderAsksForTheModelAgain() async {
        let dataSource = GateDataSource()
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        await model.prepareNewSession()
        model.newSessionDraft.newTaskTitle = "Fix the parser"
        model.chooseProvider("claude")
        model.chooseModel("default")
        XCTAssertTrue(model.canStartSession)

        model.chooseProvider("codex")

        XCTAssertEqual(model.startSessionBlockedReason, "Choose the model under Agent.")
        XCTAssertFalse(model.canStartSession)
    }

    /// A model that takes an identifier is not chosen until the identifier is
    /// typed, and the empty field is what the reason has to point at.
    func testAModelThatNeedsAnIdentifierSaysSo() async {
        let dataSource = GateDataSource()
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        await model.prepareNewSession()
        model.newSessionDraft.newTaskTitle = "Fix the parser"
        model.chooseProvider("claude")

        model.chooseModel("custom")

        XCTAssertEqual(model.startSessionBlockedReason, "Enter the model identifier for Custom model.")
        XCTAssertFalse(model.canStartSession)

        model.newSessionDraft.customModelID = "claude-opus-5"

        XCTAssertNil(model.startSessionBlockedReason)
        XCTAssertTrue(model.canStartSession)
    }

    /// An unavailable choice already carries its own explanation; the footer repeats
    /// that rather than inventing a second wording for it.
    func testAnUnavailableProviderReportsItsOwnReason() async {
        let dataSource = GateDataSource(providers: [
            WorkspaceProviderOption(
                id: "codex",
                displayName: "Codex CLI",
                systemImage: "terminal",
                availability: .unavailable(reason: "codex is not installed."),
                models: [WorkspaceModelOption(
                    id: "default",
                    displayName: "CLI default",
                    availability: .available
                )]
            ),
        ])
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        await model.prepareNewSession()
        model.newSessionDraft.newTaskTitle = "Fix the parser"

        model.chooseProvider("codex")

        XCTAssertEqual(model.startSessionBlockedReason, "codex is not installed.")
        XCTAssertFalse(model.canStartSession)
    }

    /// "Nothing is chosen" and "there is nothing to choose from yet" are different
    /// sentences, and only the first one asks the user for anything. Checking the
    /// provider before the read has landed would flash a request for a choice that
    /// cannot be made yet.
    func testAPendingProviderReadIsNotReportedAsAMissingChoice() async {
        let dataSource = GateDataSource(holdsOptionsRead: true)
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        let opening = Task { await model.prepareNewSession() }
        await dataSource.waitUntilOptionsRead()
        // Everything above Agent is already satisfied, so the read is the only
        // thing left for the reason to be about.
        model.newSessionDraft.newTaskTitle = "Fix the parser"

        XCTAssertEqual(model.sessionOptionsPhase, .loading)
        XCTAssertEqual(model.startSessionBlockedReason, "Reading the installed provider models…")
        XCTAssertFalse(model.canStartSession)

        dataSource.finishOptionsRead()
        await opening.value

        XCTAssertEqual(model.sessionOptionsPhase, .ready)
    }

    func testAFailedProviderReadIsReportedAtTheButton() async {
        let dataSource = GateDataSource(optionsFailure: "The provider catalogue could not be read.")
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.prepareNewSession()
        model.newSessionDraft.newTaskTitle = "Fix the parser"

        XCTAssertEqual(model.startSessionBlockedReason, "The provider catalogue could not be read.")
        XCTAssertFalse(model.canStartSession)
    }

    func testNoInstalledProviderPointsAtSettings() async {
        let dataSource = GateDataSource(providers: [])
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()

        await model.prepareNewSession()
        model.newSessionDraft.newTaskTitle = "Fix the parser"

        XCTAssertEqual(
            model.startSessionBlockedReason,
            "No installed provider is available. Open Settings to connect one."
        )
        XCTAssertFalse(model.canStartSession)
    }

    /// Starting a blocked session reports the same reason the footer shows. The
    /// button cannot be pressed while it refuses, so this covers the keyboard
    /// shortcut and anything else that calls the model directly.
    func testStartingWhileBlockedReportsTheSameReasonRatherThanAGenericList() async {
        let dataSource = GateDataSource()
        let model = WorkspaceViewModel(dataSource: dataSource)
        await model.load()
        await model.prepareNewSession()
        model.newSessionDraft.newTaskTitle = "Fix the parser"
        model.chooseProvider("claude")

        await model.startSession()

        XCTAssertEqual(model.newSessionError, "Choose the model under Agent.")
        XCTAssertTrue(dataSource.startedRequests.isEmpty)
    }
}

@MainActor
private final class GateDataSource: WorkspaceDataSource {
    var startedRequests: [WorkspaceSessionLaunchRequest] = []

    private let providers: [WorkspaceProviderOption]
    private let optionsFailure: String?
    private let holdsOptionsRead: Bool

    /// Held open so a test can look at the sheet mid-read. Resuming is recorded
    /// rather than dropped when it arrives first, so the handshake cannot deadlock
    /// on ordering.
    private var readStarted: CheckedContinuation<Void, Never>?
    private var readFinish: CheckedContinuation<Void, Never>?
    private var hasStartedRead = false
    private var mayFinishRead = false

    init(
        providers: [WorkspaceProviderOption] = gateInstalledProviders,
        optionsFailure: String? = nil,
        holdsOptionsRead: Bool = false
    ) {
        self.providers = providers
        self.optionsFailure = optionsFailure
        self.holdsOptionsRead = holdsOptionsRead
    }

    func waitUntilOptionsRead() async {
        guard !hasStartedRead else { return }
        await withCheckedContinuation { readStarted = $0 }
    }

    func finishOptionsRead() {
        if let readFinish {
            self.readFinish = nil
            readFinish.resume()
        } else {
            mayFinishRead = true
        }
    }

    func loadWorkspace() async throws -> WorkspacePresentationSnapshot {
        let primary = WorkspaceSourceTreeItem(
            id: "primary123",
            projectID: "project123",
            name: "main",
            url: URL(fileURLWithPath: "/tmp/byori", isDirectory: true),
            kind: .primary,
            branch: "main",
            headRevision: String(repeating: "a", count: 40),
            workingState: .clean,
            tasks: []
        )
        let project = WorkspaceProjectItem(
            id: "project123",
            name: "Byori",
            repositoryURL: URL(fileURLWithPath: "/tmp/byori", isDirectory: true),
            memorySpace: "byori_project123",
            registration: .trusted,
            sourceTrees: [primary],
            hiddenSourceTrees: []
        )
        return WorkspacePresentationSnapshot(projects: [project])
    }

    func loadSessionOptions(projectID: String) async throws -> [WorkspaceProviderOption] {
        if holdsOptionsRead {
            hasStartedRead = true
            readStarted?.resume()
            readStarted = nil
            if !mayFinishRead {
                await withCheckedContinuation { readFinish = $0 }
            }
        }
        if let optionsFailure {
            throw WorkspaceAdapterError.invalidState(optionsFailure)
        }
        return providers
    }

    func startSession(
        _ request: WorkspaceSessionLaunchRequest
    ) async throws -> WorkspaceSessionLaunchResult {
        startedRequests.append(request)
        throw WorkspaceAdapterError.unsupported("This test never launches.")
    }

    func sessionPersistenceWarning() async -> String? { nil }
}

/// The two CLIs a normal install has.
private let gateInstalledProviders: [WorkspaceProviderOption] = [
    WorkspaceProviderOption(
        id: "claude",
        displayName: "Claude Code",
        systemImage: "terminal",
        availability: .available,
        models: [
            WorkspaceModelOption(id: "default", displayName: "CLI default", availability: .available),
            WorkspaceModelOption(
                id: "custom",
                displayName: "Custom model",
                availability: .available,
                acceptsCustomIdentifier: true
            ),
        ]
    ),
    WorkspaceProviderOption(
        id: "codex",
        displayName: "Codex CLI",
        systemImage: "terminal",
        availability: .available,
        models: [
            WorkspaceModelOption(id: "default", displayName: "CLI default", availability: .available),
        ]
    ),
]
