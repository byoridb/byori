import Foundation

/// One published ByoriDB engine release.
///
/// The tag is kept verbatim next to the parsed version because the two are used
/// for different things: the version orders releases, while the tag is what the
/// installer interpolates into a download URL. Deriving one from the other would
/// mean rebuilding `v0.4.12` from `0.4.12` and guessing the prefix.
public struct EngineRelease: Equatable, Sendable {
    public let tag: String
    public let version: AppVersion
    public let releaseURL: URL?

    public init(tag: String, version: AppVersion, releaseURL: URL? = nil) {
        self.tag = tag
        self.version = version
        self.releaseURL = releaseURL
    }

    /// The charset the installer accepts for a tag it puts in a URL and records
    /// in the engine manifest. Byori validates it here as well, so a tag that
    /// could alter either is refused before it is passed on rather than after.
    public static func isSafeTag(_ tag: String) -> Bool {
        tag.range(of: #"^[A-Za-z0-9._+-]{1,64}$"#, options: .regularExpression) != nil
    }
}

/// What the last engine release check found, next to what is installed.
///
/// The engine moves independently of the app — its releases are built from
/// another repository — so "up to date" cannot be inferred from the app's own
/// version. The states are kept apart because the page says different things:
/// having failed to reach GitHub is not the same as running the newest engine,
/// and an engine installed before Byori recorded its build is neither.
public enum EngineUpdateAvailability: Equatable, Sendable {
    case unknown
    case installedUnknown(EngineRelease)
    case upToDate(EngineRelease)
    case available(EngineRelease)

    public var release: EngineRelease? {
        switch self {
        case .unknown: return nil
        case let .installedUnknown(release), let .upToDate(release), let .available(release):
            return release
        }
    }

    /// Single mapping from (installed identity, latest release) to what the UI
    /// reports, so the version row and the update button cannot disagree.
    public static func resolve(
        installedIdentity: String?,
        latest: EngineRelease?
    ) -> EngineUpdateAvailability {
        guard let latest else { return .unknown }
        guard let identity = installedIdentity,
              let installed = EngineBuildManifest.installedVersion(fromIdentity: identity) else {
            return .installedUnknown(latest)
        }
        return installed < latest.version ? .available(latest) : .upToDate(latest)
    }
}
