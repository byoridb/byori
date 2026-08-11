import CryptoKit
import Foundation

/// A text file opened for the small edits the inspector supports.
///
/// `revision` is the digest of the bytes that were read. Saving quotes it back
/// so a write can be refused when the file no longer holds what the editor was
/// started from — the agents running in these source trees write the same files
/// the user is looking at.
public struct WorkspaceFileDocument: Equatable, Sendable {
    public let relativePath: String
    public let text: String
    public let revision: String
    public let byteSize: Int

    public init(relativePath: String, text: String, revision: String, byteSize: Int) {
        self.relativePath = relativePath
        self.text = text
        self.revision = revision
        self.byteSize = byteSize
    }
}

public enum WorkspaceFileDocumentLimits {
    /// This is a "fix a typo without leaving the app" affordance, not an editor.
    /// A cap keeps a stray multi-megabyte log out of a `TextEditor` that would
    /// have to hold, diff, and re-encode the whole string on the main actor.
    public static let maxByteSize = 512 * 1_024
}

public protocol WorkspaceFileDocumentProviding: Sendable {
    func read(at root: URL, relativePath: String) async throws -> WorkspaceFileDocument
    func write(
        at root: URL,
        relativePath: String,
        text: String,
        expectedRevision: String
    ) async throws -> WorkspaceFileDocument
}

/// Reads and writes single files inside one source tree.
///
/// Everything here is written against a hostile relative path: it arrives from
/// the file outline today, but nothing about the type stops a future caller from
/// passing something else, and the blast radius of getting it wrong is a write
/// outside the user's repository.
public struct LocalWorkspaceFileDocumentService: WorkspaceFileDocumentProviding, Sendable {
    public init() {}

    public func read(at root: URL, relativePath: String) async throws -> WorkspaceFileDocument {
        let target = try Self.resolve(root: root, relativePath: relativePath)
        return try await Task.detached(priority: .userInitiated) {
            let data = try Self.readRegularFile(at: target, relativePath: relativePath)
            return try Self.makeDocument(data: data, relativePath: relativePath)
        }.value
    }

    public func write(
        at root: URL,
        relativePath: String,
        text: String,
        expectedRevision: String
    ) async throws -> WorkspaceFileDocument {
        let target = try Self.resolve(root: root, relativePath: relativePath)
        return try await Task.detached(priority: .userInitiated) {
            // Re-read rather than trusting the revision the editor was opened
            // with: between opening and saving, an agent session may have
            // rewritten the file, and overwriting that silently would destroy
            // work the user never saw.
            let current = try Self.readRegularFile(at: target, relativePath: relativePath)
            guard Self.digest(current) == expectedRevision else {
                throw WorkspaceError.fileChangedOnDisk(relativePath)
            }

            let data = Data(text.utf8)
            guard data.count <= WorkspaceFileDocumentLimits.maxByteSize else {
                throw WorkspaceError.fileNotEditable(
                    "\(relativePath) would exceed the \(WorkspaceFileDocumentLimits.maxByteSize / 1_024) KB edit limit."
                )
            }

            // An atomic write replaces the file with a freshly created one, which
            // is created with default permissions. Carrying the mode across keeps
            // a checked-in script executable after a one-character fix.
            let manager = FileManager.default
            let mode = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
            do {
                try data.write(to: target, options: [.atomic])
            } catch {
                throw WorkspaceError.fileNotEditable(
                    "cannot write \(relativePath): \(error.localizedDescription)"
                )
            }
            if let mode {
                try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            }
            return try Self.makeDocument(data: data, relativePath: relativePath)
        }.value
    }

    // MARK: - Path containment

    /// Maps a relative path to a URL that is provably inside `root`.
    ///
    /// Two separate escapes have to be closed. `..` and absolute paths are
    /// rejected outright; a symbolic link anywhere along the path is caught by
    /// comparing the fully resolved URL against the resolved root, because a
    /// link resolves at open time no matter how innocent the spelling looks.
    static func resolve(root: URL, relativePath: String) throws -> URL {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw WorkspaceError.fileNotEditable("a path inside the source tree is required")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkspaceError.fileNotEditable("path escapes the source tree: \(relativePath)")
        }

        let target = components
            .reduce(root) { $0.appendingPathComponent(String($1)) }
            .standardizedFileURL
        guard isContained(target, in: root) else {
            throw WorkspaceError.fileNotEditable("path escapes the source tree: \(relativePath)")
        }

        // A symlink is not edited through: writing would follow it to wherever it
        // points, and the outline shows links as their own kind anyway.
        if let values = try? target.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw WorkspaceError.fileNotEditable("\(relativePath) is a symbolic link.")
        }
        guard isContained(target.resolvingSymlinksInPath().standardizedFileURL, in: root) else {
            throw WorkspaceError.fileNotEditable("path escapes the source tree: \(relativePath)")
        }
        return target
    }

    /// Compares path components, not strings: `/a/bc` must not count as being
    /// inside `/a/b`.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    // MARK: - Bytes

    private static func readRegularFile(at url: URL, relativePath: String) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            throw WorkspaceError.fileNotEditable("\(relativePath) is not a regular file.")
        }
        // Checked before opening so an oversized file is never pulled into memory.
        if let size = values?.fileSize, size > WorkspaceFileDocumentLimits.maxByteSize {
            throw WorkspaceError.fileNotEditable(
                "\(relativePath) is larger than the \(WorkspaceFileDocumentLimits.maxByteSize / 1_024) KB edit limit."
            )
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw WorkspaceError.fileNotEditable(
                "cannot read \(relativePath): \(error.localizedDescription)"
            )
        }
    }

    private static func makeDocument(
        data: Data,
        relativePath: String
    ) throws -> WorkspaceFileDocument {
        // A NUL byte is the cheap tell for binary content, and decoding is the
        // rest of the answer. Round-tripping either through a text editor would
        // corrupt the file, so neither is offered for editing at all.
        guard !data.contains(0) else {
            throw WorkspaceError.fileNotEditable("\(relativePath) looks like a binary file.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.fileNotEditable("\(relativePath) is not UTF-8 text.")
        }
        return WorkspaceFileDocument(
            relativePath: relativePath,
            text: text,
            revision: digest(data),
            byteSize: data.count
        )
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
