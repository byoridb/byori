import XCTest
@testable import ByoriManagerCore

/// The engine's log is an unbounded file full of ANSI sequences, so what the app
/// shows has to be the end of it, cleaned, and small enough to lay out.
final class ServerLogReaderTests: XCTestCase {
    private var directory: URL!
    private let reader = ServerLogReader()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: String, to file: ServerLogFile) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(file.rawValue))
    }

    /// A file that was never created is not an error to report; `server.err` stays
    /// absent until something goes wrong.
    func testAMissingFileIsAStateNotAFailure() {
        let tail = reader.tail(of: .error, in: directory)

        XCTAssertEqual(tail.content, .missing)
        XCTAssertEqual(tail.byteSize, 0)
        XCTAssertFalse(tail.isTruncated)
        XCTAssertTrue(tail.path.hasSuffix("server.err"))
    }

    func testAnExistingButEmptyFileIsDistinguishedFromAMissingOne() throws {
        try write("", to: .error)

        XCTAssertEqual(reader.tail(of: .error, in: directory).content, .empty)
    }

    /// The engine writes dim, colour, and italic sequences around every field. A
    /// text editor shows them literally; the app must not.
    func testTerminalControlSequencesAreStripped() throws {
        try write(
            "\u{1B}[2m2026-08-25T02:06:04Z\u{1B}[0m \u{1B}[32m INFO\u{1B}[0m Query executed\n",
            to: .output
        )

        XCTAssertEqual(
            reader.tail(of: .output, in: directory).text,
            "2026-08-25T02:06:04Z  INFO Query executed"
        )
    }

    func testATrailingNewlineDoesNotBecomeABlankLine() throws {
        try write("first\nsecond\n", to: .output)

        let tail = reader.tail(of: .output, in: directory)
        XCTAssertEqual(tail.text, "first\nsecond")
        XCTAssertEqual(tail.lineCount, 2)
    }

    /// Only the tail is read, and the reported size is the whole file so the sheet
    /// can say how much was left out.
    func testOnlyTheEndOfALargeFileIsRead() throws {
        let line = String(repeating: "x", count: 99) + "\n"
        try write(String(repeating: line, count: 400), to: .output)

        let tail = reader.tail(of: .output, in: directory, limit: 1_000)

        XCTAssertEqual(tail.byteSize, 40_000)
        XCTAssertTrue(tail.isTruncated)
        let text = try XCTUnwrap(tail.text)
        XCTAssertLessThanOrEqual(text.utf8.count, 1_000)
        // Every retained line is whole: the fragment the seek landed inside is
        // dropped rather than shown as a line that never existed.
        for line in text.split(separator: "\n") {
            XCTAssertEqual(line.count, 99, String(line))
        }
    }

    func testTheLineBoundHoldsEvenWhenTheByteBoundDoesNot() throws {
        try write((1...50).map { "line \($0)\n" }.joined(), to: .output)

        let tail = reader.tail(of: .output, in: directory, lineLimit: 5)

        XCTAssertEqual(tail.text, "line 46\nline 47\nline 48\nline 49\nline 50")
        XCTAssertEqual(tail.lineCount, 5)
        XCTAssertTrue(tail.isTruncated)
    }

    /// A seek lands mid-character often enough that refusing to decode would be a
    /// log the user cannot read at all.
    func testInvalidUTF8DoesNotSuppressTheWholeTail() throws {
        var data = Data([0xE2, 0x9C]) // a truncated ✓
        data.append(Data("\nsecond line\n".utf8))
        try data.write(to: directory.appendingPathComponent(ServerLogFile.output.rawValue))

        XCTAssertEqual(reader.tail(of: .output, in: directory).text?.hasSuffix("second line"), true)
    }
}
