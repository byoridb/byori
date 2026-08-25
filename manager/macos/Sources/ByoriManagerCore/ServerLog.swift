import Foundation

/// The two files the engine's launch agent writes.
///
/// They are not interchangeable: the crash that explains a service which will not
/// stay up lands in `server.err`, while ordinary query traffic fills `server.log`.
/// A single "open logs" that reveals only the folder leaves the user to work that
/// out from two file names.
public enum ServerLogFile: String, CaseIterable, Identifiable, Sendable {
    case output = "server.log"
    case error = "server.err"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .output: return "서버 로그"
        case .error: return "오류 로그"
        }
    }

    public var detail: String {
        switch self {
        case .output: return "엔진이 남긴 기동과 질의 기록입니다."
        case .error: return "엔진이 표준 오류로 남긴 기록입니다. 서비스가 뜨지 않는 이유가 여기에 남습니다."
        }
    }
}

/// A bounded, display-safe view of the end of one log file.
public struct ServerLogTail: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// The engine has never written this file.
        case missing
        /// The file exists and holds nothing. Normal for `server.err`.
        case empty
        case text(String)
    }

    public let file: ServerLogFile
    public let path: String
    public let content: Content
    /// Size of the whole file, not of the tail, so the page can say how much was
    /// left out.
    public let byteSize: Int64
    public let modifiedAt: Date?
    /// True when earlier content exists that this tail does not include.
    public let isTruncated: Bool
    public let lineCount: Int

    public init(
        file: ServerLogFile,
        path: String,
        content: Content,
        byteSize: Int64,
        modifiedAt: Date?,
        isTruncated: Bool,
        lineCount: Int
    ) {
        self.file = file
        self.path = path
        self.content = content
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.isTruncated = isTruncated
        self.lineCount = lineCount
    }

    public var text: String? {
        if case let .text(value) = content { return value }
        return nil
    }
}

/// Reads the end of an engine log file into text a native label can hold.
///
/// Byori used to answer "show me the log" by revealing `~/.byoridb/logs` in the
/// Finder. That is the wrong artefact twice over: the file grows without bound —
/// tens of megabytes within days — so a text editor is asked to open all of it to
/// show the last few lines, and the engine writes ANSI colour and dim sequences,
/// which an editor renders as literal escape noise around every field.
///
/// So the tail is read by seeking rather than by loading the file, and it is bound
/// by bytes *and* lines: the byte bound keeps the read cheap, and the line bound
/// keeps what is handed to SwiftUI layout small.
public struct ServerLogReader {
    public static let defaultTailBytes = 256 * 1_024
    public static let defaultLineLimit = 400

    public init() {}

    public func tail(
        of file: ServerLogFile,
        in directory: URL,
        limit: Int = defaultTailBytes,
        lineLimit: Int = defaultLineLimit
    ) -> ServerLogTail {
        let url = directory.appendingPathComponent(file.rawValue)
        let attributes = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        )
        let modifiedAt = attributes?.contentModificationDate

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ServerLogTail(
                file: file,
                path: url.path,
                content: .missing,
                byteSize: 0,
                modifiedAt: nil,
                isTruncated: false,
                lineCount: 0
            )
        }
        defer { try? handle.close() }

        // The size comes from the handle rather than from the file attributes so
        // it describes exactly the bytes this read could see: the engine appends
        // while Settings is open.
        guard let end = try? handle.seekToEnd() else {
            return ServerLogTail(
                file: file,
                path: url.path,
                content: .missing,
                byteSize: 0,
                modifiedAt: modifiedAt,
                isTruncated: false,
                lineCount: 0
            )
        }
        let byteSize = Int64(end)
        guard end > 0 else {
            return ServerLogTail(
                file: file,
                path: url.path,
                content: .empty,
                byteSize: 0,
                modifiedAt: modifiedAt,
                isTruncated: false,
                lineCount: 0
            )
        }

        let window = UInt64(max(1, limit))
        let offset = end > window ? end - window : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else {
            return ServerLogTail(
                file: file,
                path: url.path,
                content: .empty,
                byteSize: byteSize,
                modifiedAt: modifiedAt,
                isTruncated: offset > 0,
                lineCount: 0
            )
        }

        // Lossy on purpose: a seek lands mid-character often enough, and refusing
        // to show a log because one byte pair is not valid UTF-8 would be worse
        // than one replacement glyph on the first line, which is dropped below
        // anyway when the read started mid-file.
        let decoded = SafeDisplayText.strippingTerminalControls(
            String(decoding: data, as: UTF8.self)
        )
        var lines = decoded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var droppedEarlierContent = offset > 0
        if droppedEarlierContent, lines.count > 1 {
            // The first line of a mid-file read is a fragment of a line that
            // started before the window.
            lines.removeFirst()
        }
        // A trailing newline yields one empty element that would render as a
        // blank last line.
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        if lines.count > lineLimit {
            lines = Array(lines.suffix(lineLimit))
            droppedEarlierContent = true
        }
        guard !lines.isEmpty else {
            return ServerLogTail(
                file: file,
                path: url.path,
                content: .empty,
                byteSize: byteSize,
                modifiedAt: modifiedAt,
                isTruncated: droppedEarlierContent,
                lineCount: 0
            )
        }
        return ServerLogTail(
            file: file,
            path: url.path,
            content: .text(lines.joined(separator: "\n")),
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            isTruncated: droppedEarlierContent,
            lineCount: lines.count
        )
    }
}
