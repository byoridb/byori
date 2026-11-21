import ByoriManagerCore
import XCTest
@testable import ByoriManager

final class AgentInventoryPresentationTests: XCTestCase {
    func testOnlySuccessfulEmptyInventoryReportsZero() {
        XCTAssertEqual(AgentInventoryPresentation.countLabel(state: .ready, count: 0), "0개")
        XCTAssertEqual(AgentInventoryPresentation.countLabel(state: .unavailable, count: 0), "확인 실패")
        XCTAssertEqual(AgentInventoryPresentation.countLabel(state: .cliMissing, count: 0), "CLI 필요")
        XCTAssertEqual(AgentInventoryPresentation.countLabel(state: nil, count: 0), "확인 중")
    }

    func testPartialAndTruncatedScansDoNotClaimCompleteCount() {
        XCTAssertEqual(
            AgentInventoryPresentation.countLabel(state: .unavailable, count: 3),
            "일부 확인 · 3개"
        )
        XCTAssertEqual(
            AgentInventoryPresentation.countLabel(state: .ready, count: 200, truncated: true),
            "200개 표시 · 일부 목록"
        )
    }

    func testQueryMatchesNamesAcrossCaseAccentsAndKorean() {
        XCTAssertTrue(AgentInventoryQuery(text: "  BYORI  ").matches(name: "byoridb-memory", isByoriManaged: true))
        XCTAssertTrue(AgentInventoryQuery(text: "cafe").matches(name: "Café", isByoriManaged: false))
        XCTAssertTrue(AgentInventoryQuery(text: "업무").matches(name: "업무-검색", isByoriManaged: false))
        XCTAssertFalse(AgentInventoryQuery(text: "업무").matches(name: "byoridb", isByoriManaged: true))
    }

    func testOwnershipFilterAppliesAlongsideSearch() {
        let managed = AgentInventoryQuery(text: "memory", filter: .byoriManaged)
        XCTAssertTrue(managed.matches(name: "byoridb-memory", isByoriManaged: true))
        XCTAssertFalse(managed.matches(name: "user-memory", isByoriManaged: false))
        XCTAssertFalse(managed.matches(name: "byori-design", isByoriManaged: true))

        let external = AgentInventoryQuery(filter: .other)
        XCTAssertTrue(external.matches(name: "cloud-connector", isByoriManaged: false))
        XCTAssertFalse(external.matches(name: "byoridb", isByoriManaged: true))
    }

    func testRegistrationVerificationDoesNotClaimLiveConnectivity() {
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: true, inventoryState: .unavailable, serverStatus: nil
            ),
            "등록됨 · 연결 미확인"
        )
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: true, inventoryState: .ready, serverStatus: .configured
            ),
            "등록됨 · 연결 미확인"
        )
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: true, inventoryState: .unavailable, serverStatus: .connected
            ),
            "등록됨 · 연결 미확인",
            "A failed scan must not reuse a stale connected status."
        )
    }

    func testReportedConnectionFailureRemainsVisibleForRegisteredServer() {
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: true, inventoryState: .ready, serverStatus: .unavailable
            ),
            "등록됨 · 연결 실패"
        )
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: true, inventoryState: .ready, serverStatus: .connected
            ),
            "연결 확인됨"
        )
    }

    func testMissingRegistrationIsUnknownUntilInventorySucceeds() {
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: false, inventoryState: .unavailable, serverStatus: nil
            ),
            "등록 미확인"
        )
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: false, inventoryState: .ready, serverStatus: nil
            ),
            "미등록"
        )
    }

    func testIndependentHealthyProbeSurvivesWholeInventoryFailure() {
        let probe = ByoriMCPProbe(registrationConfirmed: true, status: .connected)
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: false, inventoryState: .unavailable, serverStatus: nil,
                independentProbe: probe
            ),
            "연결 확인됨"
        )
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPVerifiedStatus(
                registrationConfirmed: false, inventoryState: .unavailable, serverStatus: nil,
                independentProbe: probe
            ),
            .connected,
            "The icon must use the same independent verification as the label."
        )
    }

    func testFailedIndependentProbeDoesNotReusePreviousRegistrationOrHealth() {
        let probe = ByoriMCPProbe(registrationConfirmed: false, status: .unknown)
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: true, inventoryState: .unavailable, serverStatus: .connected,
                independentProbe: probe
            ),
            "등록 미확인"
        )
        XCTAssertNil(
            AgentInventoryPresentation.byoriMCPVerifiedStatus(
                registrationConfirmed: true, inventoryState: .unavailable, serverStatus: .connected,
                independentProbe: probe
            )
        )
    }

    func testIndependentRegistrationWithoutHealthDoesNotClaimConnection() {
        for status in [MCPServerStatus.configured, .unknown] {
            let probe = ByoriMCPProbe(registrationConfirmed: true, status: status)
            XCTAssertEqual(
                AgentInventoryPresentation.byoriMCPStatus(
                    registrationConfirmed: true, inventoryState: .unavailable, serverStatus: .connected,
                    independentProbe: probe
                ),
                "등록됨 · 연결 미확인"
            )
            XCTAssertNotEqual(
                AgentInventoryPresentation.byoriMCPVerifiedStatus(
                    registrationConfirmed: true, inventoryState: .unavailable, serverStatus: .connected,
                    independentProbe: probe
                ),
                .connected
            )
        }
    }

    func testSuccessfulListCannotProveRegistrationWhenIndependentProbeFails() {
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: true, inventoryState: .ready, serverStatus: .connected,
                independentProbe: ByoriMCPProbe(registrationConfirmed: false, status: .unknown)
            ),
            "등록 미확인",
            "An unknown managed-registration probe is not evidence that registration is missing."
        )
    }

    func testIndependentHealthRequiresManagedRegistration() {
        let probe = ByoriMCPProbe(registrationConfirmed: false, status: .connected)
        XCTAssertEqual(
            AgentInventoryPresentation.byoriMCPStatus(
                registrationConfirmed: true, inventoryState: .ready, serverStatus: .connected,
                independentProbe: probe
            ),
            "미등록"
        )
        XCTAssertNil(
            AgentInventoryPresentation.byoriMCPVerifiedStatus(
                registrationConfirmed: true, inventoryState: .ready, serverStatus: .connected,
                independentProbe: probe
            ),
            "A same-named external server must not become a verified Byori-managed connection."
        )
    }

    func testIndependentFailureAndAuthenticationRemainVisible() {
        let expectations: [(MCPServerStatus, String)] = [
            (.unavailable, "등록됨 · 연결 실패"),
            (.authenticationRequired, "등록됨 · 인증 필요"),
            (.disabled, "등록됨 · 비활성"),
            (.pendingApproval, "등록됨 · 승인 대기")
        ]
        for (status, label) in expectations {
            XCTAssertEqual(
                AgentInventoryPresentation.byoriMCPStatus(
                    registrationConfirmed: true, inventoryState: .unavailable, serverStatus: .connected,
                    independentProbe: ByoriMCPProbe(registrationConfirmed: true, status: status)
                ),
                label
            )
        }
        XCTAssertNil(
            AgentInventoryPresentation.byoriMCPVerifiedStatus(
                registrationConfirmed: true, inventoryState: .unavailable, serverStatus: .connected
            ),
            "A failed list without an independent probe cannot light the connected icon."
        )
    }
}
