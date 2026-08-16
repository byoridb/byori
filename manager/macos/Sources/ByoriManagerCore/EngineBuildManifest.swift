import Foundation

/// What the installer recorded about the engine binary it installed.
///
/// `byoridb-server` exposes no `--version` and ignores its arguments, so the
/// installed build cannot be identified by asking it. Probing is not an option
/// either: on the pinned engine, `--version` starts a normal server, and a status
/// refresh must never bring up a second database. The installer therefore writes
/// this file next to the binary, and this is the only thing that answers "which
/// engine is actually installed" without running `strings` over it.
public struct EngineBuildManifest: Equatable, Sendable {
    /// The engine release tag, absent when a local binary was installed with
    /// `--binary`.
    public let tag: String?
    public let target: String?
    public let sha256: String?
    public let installedAt: Date?

    public init(tag: String?, target: String?, sha256: String?, installedAt: Date?) {
        self.tag = tag
        self.target = target
        self.sha256 = sha256
        self.installedAt = installedAt
    }

    /// A bounded identity for one line of UI: the tag when there is one, and
    /// enough of the digest to tell two builds of the same tag apart.
    ///
    /// Nil when the file says nothing usable, which the caller must present as
    /// "not recorded" rather than as a healthy unknown: engines installed before
    /// the installer began recording this have no file at all.
    public var displayIdentity: String? {
        let shortDigest = sha256.map { String($0.prefix(12)) }
        switch (tag, shortDigest) {
        case let (tag?, digest?): return "\(tag) · \(digest)"
        case let (tag?, nil): return tag
        case let (nil, digest?): return "로컬 빌드 · \(digest)"
        case (nil, nil): return nil
        }
    }

    /// Reads the manifest, or nil when it is missing, unreadable, or not the
    /// shape this client writes.
    ///
    /// Never throws. A damaged manifest is a reporting gap, and refusing to
    /// report status because of one would be worse than saying "not recorded".
    public static func read(at url: URL) -> EngineBuildManifest? {
        guard let data = try? Data(contentsOf: url),
              data.count <= 64 * 1_024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let manifest = EngineBuildManifest(
            tag: bounded(root["tag"], pattern: #"^[A-Za-z0-9._+-]{1,64}$"#),
            target: bounded(root["target"], pattern: #"^[A-Za-z0-9._-]{1,64}$"#),
            sha256: bounded(root["sha256"], pattern: #"^[a-f0-9]{64}$"#),
            installedAt: (root["installed_at"] as? String).flatMap(parseTimestamp)
        )
        // A file that parsed but carried nothing recognizable is the same as no
        // file: reporting an empty identity as a record would be a lie.
        guard manifest != EngineBuildManifest(tag: nil, target: nil, sha256: nil, installedAt: nil) else {
            return nil
        }
        return manifest
    }

    /// Values are written by the installer and read back into the UI, so each is
    /// validated against the exact shape it should have rather than trusted for
    /// being local.
    private static func bounded(_ value: Any?, pattern: String) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
