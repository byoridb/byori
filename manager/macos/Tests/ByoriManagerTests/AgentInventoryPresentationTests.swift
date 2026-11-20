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
}
