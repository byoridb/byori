import Foundation

/// Copies the local configuration a new worktree needs but Git will not provide.
///
/// A worktree starts with the tracked files of its branch and nothing else. The
/// files that make a checkout actually runnable are usually the ones deliberately
/// kept out of Git — `.env`, a direnv file, a pinned toolchain version — so a
/// fresh worktree looks identical to the primary checkout and then fails to run,
/// with nothing on screen to say why. Byori creates these worktrees on the user's
/// behalf, so it carries that configuration across.
///
/// Deliberately an allowlist of small, root-level names rather than "everything
/// Git ignores": ignored paths are also where `node_modules`, build output and
/// caches live, and copying those would turn creating a worktree into copying
/// gigabytes. Everything else stays the user's job — and stays visible, because
/// the carried files are reported.
public struct WorktreeLocalConfig: Sendable {
    /// Root-relative paths considered for copying, in the order they are tried.
    ///
    /// `.env.example` and friends are intentionally absent: they are normally
    /// tracked, so the worktree already has them.
    public static let candidates: [String] = [
        ".env",
        ".env.local",
        ".env.development.local",
        ".env.test.local",
        ".env.production.local",
        ".envrc",
        ".tool-versions",
        ".node-version",
        ".nvmrc",
        ".python-version",
        ".ruby-version",
        ".claude/settings.local.json",
    ]

    /// A carried file has to be small. The allowlist should already keep this
    /// from mattering, but a name on it can be anything on disk, and copying a
    /// large file silently is worse than skipping it.
    public static let byteLimit = 256 * 1_024

    public init() {}

    /// Which candidates are present in `source`, absent from `destination`, and
    /// small enough to copy. Separate from `carry` so the decision is testable
    /// without touching a real worktree.
    ///
    /// The file manager is a parameter rather than stored state: `FileManager` is
    /// not `Sendable`, and this type is passed across isolation boundaries.
    public func plan(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        Self.candidates.filter { relativePath in
            let origin = source.appendingPathComponent(relativePath)
            let target = destination.appendingPathComponent(relativePath)
            guard !fileManager.fileExists(atPath: target.path) else { return false }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: origin.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return false
            }
            // A symlink would be copied as a link into a directory where its
            // target may not exist, so it is skipped rather than reproduced.
            guard let attributes = try? fileManager.attributesOfItem(atPath: origin.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size <= Self.byteLimit else {
                return false
            }
            return true
        }
    }

    /// Copies the planned files and returns what was carried.
    ///
    /// Never overwrites, and never fails the caller: a worktree that exists with
    /// one config file missing is more useful than no worktree at all, so a copy
    /// that fails is reported by its absence from the result.
    @discardableResult
    public func carry(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        var carried: [String] = []
        for relativePath in plan(from: source, to: destination, fileManager: fileManager) {
            let origin = source.appendingPathComponent(relativePath)
            let target = destination.appendingPathComponent(relativePath)
            let parent = target.deletingLastPathComponent()
            do {
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                // copyItem preserves POSIX permissions, which matters: a `.env`
                // at 0600 must not land at 0644 in the new worktree.
                try fileManager.copyItem(at: origin, to: target)
                carried.append(relativePath)
            } catch {
                continue
            }
        }
        return carried
    }
}
