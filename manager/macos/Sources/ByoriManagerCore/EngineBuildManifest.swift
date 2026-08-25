import Foundation

/// What the installer recorded about the engine binary it installed.
///
/// Engine 0.4.0 answers `--version` without starting a server, so the binary can
/// finally identify itself. Older engines cannot: they ignore every argument, and
/// `byoridb-server --version` boots a full server — which a status refresh must
/// never do, because it would bring up a second database against the same data
/// directory.
///
/// So the recorded tag is what decides whether probing is safe, and it remains
/// the answer for engines that were installed before Byori recorded anything.
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

    /// Recovers the comparable version from whatever identity was reported.
    ///
    /// Both forms this app produces start with the version — `0.4.2 (commit …,
    /// release)` from the binary and `v0.4.2 · digest` from the manifest — so the
    /// leading token is the whole answer. A local build (`로컬 빌드 · digest`)
    /// deliberately yields nil: it has no place in the release ordering, and
    /// calling it older than the newest tag would offer to overwrite a binary the
    /// user installed on purpose.
    public static func installedVersion(fromIdentity identity: String) -> AppVersion? {
        guard let token = identity.split(separator: " ").first else { return nil }
        return AppVersion(String(token))
    }

    /// The first engine release that parses its arguments instead of ignoring
    /// them. Below this, `--version` starts a server.
    public static let versionFlagMinimum = "v0.4.0"

    /// Whether `byoridb-server --version` can be run safely.
    ///
    /// Requires a recorded tag at or above `versionFlagMinimum`. An unrecorded or
    /// older engine is never probed: the cost of guessing wrong is a second
    /// database process started against the live data directory, which is far
    /// worse than reporting the recorded identity instead.
    public var allowsVersionProbe: Bool {
        guard let tag, let found = AppVersion(tag),
              let minimum = AppVersion(Self.versionFlagMinimum) else {
            return false
        }
        return found >= minimum
    }

    /// Parses `byoridb-server --version`, which prints
    /// `byoridb-server 0.4.0 (commit fbeb4ac55417, release)`.
    ///
    /// The binary's own name is dropped — the row it fills is already labelled
    /// with it — and the commit and profile are kept, because those are what
    /// distinguish two builds of one tag. Bounded and charset-checked: this
    /// becomes UI text.
    ///
    /// The leading name is optional rather than required. clap prints it, but the
    /// contract worth holding is "a version, with whatever build detail follows",
    /// not the exact framing of one release.
    public static func version(fromVersionOutput output: String) -> String? {
        guard var line = output
            .split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }),
            line.utf8.count <= 200 else {
            return nil
        }
        if let space = line.firstIndex(of: " "),
           line[line.startIndex] .isLetter {
            let name = line[line.startIndex..<space]
            guard name.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
                return nil
            }
            line = String(line[line.index(after: space)...])
        }
        guard line.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9 ().,+_-]*$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return line
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
