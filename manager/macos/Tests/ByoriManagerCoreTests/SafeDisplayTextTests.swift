import XCTest
@testable import ByoriManagerCore

final class SafeDisplayTextTests: XCTestCase {
    func testStripsTerminalSequencesAndControlStringPayloads() {
        let sanitized = SafeDisplayText.strippingTerminalControls(
            "\u{001B}[32mready\u{001B}[0m\u{000D}\u{0000}\tvalue\n"
                + "\u{001B}]8;;https://secret.invalid\u{0007}link"
                + "\u{001B}Pprivate-payload\u{001B}\\done"
                + "\u{009B}2Ktail"
        )

        XCTAssertEqual(sanitized, "ready\tvalue\nlinkdonetail")
        XCTAssertFalse(sanitized.contains("secret"))
        XCTAssertFalse(sanitized.contains("private"))
    }

    func testPreservesUnicodeAndUserReadableWhitespace() {
        XCTAssertEqual(
            SafeDisplayText.strippingTerminalControls("설치 완료 ✅\n다음\t단계"),
            "설치 완료 ✅\n다음\t단계"
        )
    }
}
