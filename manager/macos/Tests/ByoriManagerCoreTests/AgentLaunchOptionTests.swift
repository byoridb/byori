import XCTest
@testable import ByoriManagerCore

/// The catalogue exists so the user picks a control instead of remembering a
/// flag, which only holds if the flags are the CLI's real ones and an untouched
/// control contributes nothing.
final class AgentLaunchOptionTests: XCTestCase {
    func testAnUntouchedOptionContributesNoArguments() {
        for option in AgentLaunchOptionCatalog.options(for: "claude")
            + AgentLaunchOptionCatalog.options(for: "codex") {
            XCTAssertEqual(option.arguments(selection: nil), [], option.id)
        }
    }

    func testAFlagPassesItselfAndAChoicePassesItsValue() {
        let claude = AgentLaunchOptionCatalog.options(for: "claude")
        let skip = try! XCTUnwrap(claude.first { $0.id == "claude.dangerously-skip-permissions" })
        XCTAssertEqual(skip.arguments(selection: skip.flag), ["--dangerously-skip-permissions"])

        let mode = try! XCTUnwrap(claude.first { $0.id == "claude.permission-mode" })
        XCTAssertEqual(mode.arguments(selection: "plan"), ["--permission-mode", "plan"])
    }

    func testAChoiceRefusesAValueTheCLIDoesNotList() {
        let mode = AgentLaunchOptionCatalog.options(for: "claude")
            .first { $0.id == "claude.permission-mode" }
        // A stale or hand-edited selection must not become argv the CLI will
        // reject; passing nothing is the safe direction.
        XCTAssertEqual(mode?.arguments(selection: "yolo"), [])
        XCTAssertEqual(mode?.arguments(selection: ""), [])
    }

    func testDangerousOptionsAreMarkedAndAreTheOnesThatRemoveConfirmation() {
        let dangerous = (AgentLaunchOptionCatalog.options(for: "claude")
            + AgentLaunchOptionCatalog.options(for: "codex"))
            .filter(\.isDangerous)
            .map(\.flag)
            .sorted()
        XCTAssertEqual(dangerous, [
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-skip-permissions",
        ])
    }

    /// Pinned to `claude --help` and `codex --help`. A rename upstream should
    /// fail here rather than at launch, where the user sees only a parse error.
    func testFlagsMatchWhatTheCLIsDocument() {
        XCTAssertEqual(
            AgentLaunchOptionCatalog.options(for: "claude").map(\.flag),
            ["--dangerously-skip-permissions", "--permission-mode"]
        )
        XCTAssertEqual(
            AgentLaunchOptionCatalog.options(for: "codex").map(\.flag),
            [
                "--dangerously-bypass-approvals-and-sandbox",
                "--sandbox",
                "--ask-for-approval",
            ]
        )
        XCTAssertEqual(
            AgentLaunchOptionCatalog.options(for: "codex")
                .first { $0.id == "codex.sandbox" }?
                .arguments(selection: "danger-full-access"),
            ["--sandbox", "danger-full-access"]
        )
    }

    func testACustomProviderHasNoKnownOptions() {
        // Byori did not describe it, so it does not claim to know its flags.
        XCTAssertTrue(AgentLaunchOptionCatalog.options(for: "custom-thing").isEmpty)
        XCTAssertTrue(AgentLaunchOptionCatalog.options(for: "").isEmpty)
    }
}

final class AgentLaunchArgumentComposerTests: XCTestCase {
    private let claude = AgentLaunchOptionCatalog.options(for: "claude")

    private func compose(_ selections: [String: String], typed: [String] = []) -> [String] {
        AgentLaunchArgumentComposer.arguments(
            options: claude,
            selections: selections,
            typed: typed
        )
    }

    func testNothingSelectedAndNothingTypedPassesNothing() {
        XCTAssertEqual(compose([:]), [])
    }

    func testSelectionsComeBeforeTypedArguments() {
        XCTAssertEqual(
            compose(
                ["claude.permission-mode": "plan"],
                typed: ["--verbose"]
            ),
            ["--permission-mode", "plan", "--verbose"]
        )
    }

    func testATypedFlagIsNotPassedTwiceWhenTheControlAgrees() {
        // Both say the same thing; argv should say it once.
        let arguments = compose(
            ["claude.dangerously-skip-permissions": "--dangerously-skip-permissions"],
            typed: ["--dangerously-skip-permissions"]
        )
        XCTAssertEqual(arguments, ["--dangerously-skip-permissions"])
        XCTAssertEqual(arguments.filter { $0 == "--dangerously-skip-permissions" }.count, 1)
    }

    func testATypedValueWinsOverTheControlForTheSameFlag() {
        // The control is dropped rather than emitted before the typed one: a CLI
        // that takes the last occurrence would land on the typed value anyway,
        // and one that rejects duplicates would refuse to start at all.
        XCTAssertEqual(
            compose(
                ["claude.permission-mode": "plan"],
                typed: ["--permission-mode", "acceptEdits"]
            ),
            ["--permission-mode", "acceptEdits"]
        )
    }

    func testAStaleSelectionForAnotherProviderIsIgnored() {
        // Switching provider leaves the previous provider's keys in the draft.
        XCTAssertEqual(compose(["codex.sandbox": "danger-full-access"]), [])
    }
}
