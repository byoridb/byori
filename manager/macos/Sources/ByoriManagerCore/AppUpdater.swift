import Foundation

/// A release version ordered the way Byori tags them: `v0.3.0`, optionally with
/// a prerelease suffix.
public struct AppVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let numbers: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        guard !value.isEmpty else { return nil }

        let core: Substring
        var suffix: String?
        if let separator = value.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            core = value[value.startIndex..<separator]
            suffix = String(value[value.index(after: separator)...])
        } else {
            core = value[...]
        }

        var numbers: [Int] = []
        for part in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        guard !numbers.isEmpty else { return nil }
        while numbers.count < 3 {
            numbers.append(0)
        }

        self.numbers = numbers
        self.prerelease = (suffix?.isEmpty ?? true) ? nil : suffix
    }

    public var description: String {
        let core = numbers.map(String.init).joined(separator: ".")
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right {
                return left < right
            }
        }
        // A prerelease sorts below the release it leads to, so 0.4.0-beta.1
        // never looks newer than 0.4.0.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(left), .some(right)):
            return left < right
        }
    }
}

public struct AvailableUpdate: Sendable, Equatable {
    public let version: AppVersion
    public let assetName: String
    public let downloadURL: URL
    public let releaseURL: URL?

    public init(version: AppVersion, assetName: String, downloadURL: URL, releaseURL: URL? = nil) {
        self.version = version
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.releaseURL = releaseURL
    }
}

public enum AppUpdateStatus: Sendable, Equatable {
    case upToDate(AppVersion)
    case available(AvailableUpdate)
}

/// What an update run actually did. Finding nothing to install is a normal
/// outcome, so it is a case here rather than a thrown error — and the two cases
/// are not interchangeable to the caller: only `.installed` leaves a staged
/// bundle behind a helper that is waiting for this process to quit.
public enum AppUpdateOutcome: Sendable, Equatable {
    case alreadyCurrent(AppVersion)
    case installed(OperationResult)

    /// True when the swap still has to happen after the app exits.
    public var requiresRelaunch: Bool {
        if case .installed = self { return true }
        return false
    }

    public var result: OperationResult {
        switch self {
        case let .alreadyCurrent(version):
            // The version goes in parentheses rather than into the sentence:
            // Korean particles change with the preceding sound, and the digit
            // this one would follow varies with the release.
            return OperationResult(
                summary: "이미 최신 버전입니다",
                detail: "설치된 버전(\(version))이 가장 최신 릴리스입니다."
            )
        case let .installed(result):
            return result
        }
    }
}

/// Steps an update passes through. Verification runs several external tools and
/// Gatekeeper may reach the network, so a single spinner leaves the user unable
/// to tell slow from stuck.
public enum AppUpdateStage: Sendable, Equatable {
    case checking
    case downloading
    case verifyingImage
    case verifyingApp
    case preparing
    case relaunching

    public var message: String {
        switch self {
        case .checking: return "새 버전 확인 중…"
        case .downloading: return "새 버전 내려받는 중…"
        case .verifyingImage: return "디스크 이미지의 서명과 공증 확인 중…"
        case .verifyingApp: return "앱의 서명과 공증 확인 중…"
        case .preparing: return "교체 준비 중…"
        case .relaunching: return "앱을 종료하고 새 버전으로 다시 엽니다…"
        }
    }

    /// Rough share of the whole operation, for a determinate progress bar.
    public var fraction: Double {
        switch self {
        case .checking: return 0.05
        case .downloading: return 0.35
        case .verifyingImage: return 0.6
        case .verifyingApp: return 0.8
        case .preparing: return 0.95
        case .relaunching: return 1.0
        }
    }
}

public typealias AppUpdateProgress = @Sendable (AppUpdateStage) -> Void

/// A verified copy of the new app, sitting on a mounted image and ready to be
/// swapped in. Holding the mount point keeps the disk image attached until the
/// caller either applies or discards the update.
public struct StagedUpdate: Sendable, Equatable {
    public let version: AppVersion
    public let appPath: String
    public let mountPoint: String
    public let imagePath: String
}

public protocol ReleaseFetching: Sendable {
    func data(from url: URL) async throws -> Data
    func download(from url: URL, to destination: URL) async throws
}

public struct URLSessionReleaseFetcher: ReleaseFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(from url: URL) async throws -> Data {
        let (payload, response) = try await session.data(for: request(for: url))
        try Self.requireSuccess(response, url: url)
        return payload
    }

    public func download(from url: URL, to destination: URL) async throws {
        let (temporary, response) = try await session.download(for: request(for: url))
        try Self.requireSuccess(response, url: url)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Byori", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func requireSuccess(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ManagerError.commandFailed("업데이트 확인", Int32(http.statusCode), url.absoluteString)
        }
    }
}

/// Parses the subset of the GitHub releases payload Byori depends on. Kept
/// separate from the updater so the selection rules are testable without a
/// network or a signed disk image.
public enum ReleaseCatalog {
    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public static func latestUpdate(from data: Data) throws -> AvailableUpdate {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw ManagerError.prerequisite("최신 릴리스가 초안 또는 프리릴리스입니다.")
        }
        guard let version = AppVersion(release.tagName) else {
            throw ManagerError.prerequisite("릴리스 태그를 해석할 수 없습니다: \(release.tagName)")
        }
        // The DMG carries its version in the file name, so there is no fixed
        // "latest" asset URL to hard-code; pick it out of the release instead.
        let images = release.assets.filter { $0.name.hasSuffix(".dmg") }
        let chosen = images.first { $0.name.hasSuffix("-universal.dmg") } ?? images.first
        guard let asset = chosen, let url = URL(string: asset.browserDownloadURL) else {
            throw ManagerError.prerequisite("릴리스 \(release.tagName)에 설치 가능한 DMG가 없습니다.")
        }
        return AvailableUpdate(
            version: version,
            assetName: asset.name,
            downloadURL: url,
            releaseURL: release.htmlURL.flatMap(URL.init(string:))
        )
    }
}

/// Downloads, verifies, and installs a newer Byori.app.
///
/// The trust rule is that HTTPS decides nothing: a downloaded image is accepted
/// only when it carries a Developer ID signature from the expected team *and*
/// Gatekeeper reports it as notarized. Both the disk image and the app inside it
/// are checked, because only the outer signature travels with the download.
public actor AppUpdater {
    public struct Configuration: Sendable {
        public var repository: String
        public var teamIdentifier: String

        public init(repository: String = "byoridb/byori", teamIdentifier: String = "4J8MZGZJ2B") {
            self.repository = repository
            self.teamIdentifier = teamIdentifier
        }
    }

    private let configuration: Configuration
    private let bundleURL: URL
    private let currentVersion: AppVersion
    private let runner: any CommandRunning
    private let fetcher: any ReleaseFetching
    private let fileManager: FileManager

    public init(
        bundleURL: URL,
        currentVersion: AppVersion,
        configuration: Configuration = Configuration(),
        runner: any CommandRunning = ProcessCommandRunner(),
        fetcher: any ReleaseFetching = URLSessionReleaseFetcher(),
        fileManager: FileManager = .default
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.currentVersion = currentVersion
        self.configuration = configuration
        self.runner = runner
        self.fetcher = fetcher
        self.fileManager = fileManager
    }

    public func check() async throws -> AppUpdateStatus {
        let endpoint = URL(
            string: "https://api.github.com/repos/\(configuration.repository)/releases/latest"
        )
        guard let endpoint else {
            throw ManagerError.prerequisite("릴리스 주소를 만들 수 없습니다.")
        }
        let update = try ReleaseCatalog.latestUpdate(from: try await fetcher.data(from: endpoint))
        guard update.version > currentVersion else {
            return .upToDate(currentVersion)
        }
        return .available(update)
    }

    /// Downloads the image and refuses it unless every check passes. The disk
    /// image stays mounted on success; call `discard` or `apply` to release it.
    public func stage(
        _ update: AvailableUpdate,
        progress: AppUpdateProgress? = nil
    ) async throws -> StagedUpdate {
        guard update.version > currentVersion else {
            throw ManagerError.prerequisite(
                "설치된 \(currentVersion)보다 낮거나 같은 \(update.version)로는 업데이트하지 않습니다."
            )
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("byori-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent(update.assetName)
        progress?(.downloading)
        try await fetcher.download(from: update.downloadURL, to: image)

        progress?(.verifyingImage)
        try await verifySignature(path: image.path, label: "다운로드한 디스크 이미지")

        let mountPoint = try await attach(image: image)
        do {
            let app = try locateApp(inside: mountPoint)
            progress?(.verifyingApp)
            try await verifySignature(path: app, label: "업데이트할 앱")
            try await verifyStructure(appPath: app)
            try verify(appPath: app, matches: update.version)
            return StagedUpdate(
                version: update.version,
                appPath: app,
                mountPoint: mountPoint,
                imagePath: image.path
            )
        } catch {
            await detach(mountPoint: mountPoint)
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    public func discard(_ staged: StagedUpdate) async {
        await detach(mountPoint: staged.mountPoint)
        try? fileManager.removeItem(
            at: URL(fileURLWithPath: staged.imagePath).deletingLastPathComponent()
        )
    }

    /// Hands the swap to a detached helper, because the app cannot replace its
    /// own bundle and relaunch itself. The caller terminates once this returns.
    public func apply(
        _ staged: StagedUpdate,
        progress: AppUpdateProgress? = nil
    ) async throws -> OperationResult {
        progress?(.preparing)
        let target = bundleURL.path
        guard fileManager.fileExists(atPath: target) else {
            throw ManagerError.missingResource(target)
        }
        // Writability is a property of the enclosing directory: replacing the
        // bundle means creating and renaming siblings, not editing it in place.
        let container = bundleURL.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: container) else {
            throw ManagerError.prerequisite(
                "\(container)에 쓸 권한이 없어 자동 교체할 수 없습니다. "
                    + "다운로드한 이미지에서 직접 설치해 주세요: \(staged.imagePath)"
            )
        }

        let script = URL(fileURLWithPath: staged.imagePath)
            .deletingLastPathComponent()
            .appendingPathComponent("apply-update.sh")
        try Data(Self.applyScript.utf8).write(to: script)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            staged.appPath,
            target,
            staged.mountPoint,
        ]
        try process.run()
        progress?(.relaunching)

        return OperationResult(
            summary: "Byori \(staged.version) 업데이트를 적용합니다. 앱이 종료된 뒤 자동으로 다시 열립니다.",
            detail: "교체 대상: \(target)"
        )
    }

    /// Waits for the app to exit, then swaps the bundle. The old bundle is moved
    /// aside rather than deleted first, so a failed move can be put back instead
    /// of leaving no app at all.
    static let applyScript = """
    #!/bin/sh
    set -e
    pid="$1"
    source="$2"
    target="$3"
    mount_point="$4"
    # Iterations of 0.2s to wait for the app; overridable so the bound itself
    # can be tested without a three-minute test.
    max_wait="${5:-900}"

    # Bounded: if the app refuses to quit, clean up rather than waiting forever.
    waited=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
      /bin/sleep 0.2
      waited=$((waited + 1))
      if [ "$waited" -gt "$max_wait" ]; then
        /usr/bin/hdiutil detach "$mount_point" -quiet || true
        exit 1
      fi
    done

    /usr/bin/ditto "$source" "$target.byori-new"
    if [ -e "$target" ]; then
      /bin/mv "$target" "$target.byori-old"
    fi
    if ! /bin/mv "$target.byori-new" "$target"; then
      [ -e "$target.byori-old" ] && /bin/mv "$target.byori-old" "$target"
      /usr/bin/hdiutil detach "$mount_point" -quiet || true
      exit 1
    fi
    /bin/rm -rf "$target.byori-old"
    /usr/bin/hdiutil detach "$mount_point" -quiet || true
    /usr/bin/open "$target"

    """

    private func verifySignature(path: String, label: String) async throws {
        let signature = await runner.run(CommandSpec(
            executable: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", path],
            timeout: 60
        ))
        guard signature.succeeded else {
            throw ManagerError.verificationFailed("서명이 없습니다: \(label)")
        }
        let team = Self.teamIdentifier(fromCodesignOutput: signature.output)
        guard let team else {
            throw ManagerError.verificationFailed("팀 식별자를 읽을 수 없습니다: \(label)")
        }
        guard team == configuration.teamIdentifier else {
            throw ManagerError.verificationFailed(
                "다른 개발자(\(team))의 서명입니다. 예상: \(configuration.teamIdentifier) — \(label)"
            )
        }

        let assessment = await runner.run(CommandSpec(
            executable: "/usr/sbin/spctl",
            arguments: [
                "--assess", "--type", "open",
                "--context", "context:primary-signature",
                "--verbose", path,
            ],
            timeout: 120
        ))
        guard Self.isNotarized(spctlOutput: assessment.output), assessment.succeeded else {
            // The label is trailing on purpose: Korean subject particles vary
            // with the final letter of the preceding noun, and these labels are
            // interpolated, so a fixed particle would be wrong half the time.
            throw ManagerError.verificationFailed(
                "공증되지 않았습니다. 설치를 중단합니다 — \(label)"
            )
        }
    }

    private func verifyStructure(appPath: String) async throws {
        let result = await runner.run(CommandSpec(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", appPath],
            timeout: 180
        ))
        guard result.succeeded else {
            throw ManagerError.verificationFailed("업데이트할 앱의 서명이 손상되었습니다.")
        }
    }

    private func verify(appPath: String, matches expected: AppVersion) throws {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let info = raw as? [String: Any],
            let text = info["CFBundleShortVersionString"] as? String,
            let version = AppVersion(text)
        else {
            throw ManagerError.verificationFailed("업데이트할 앱의 버전을 읽을 수 없습니다.")
        }
        // The release tag is what the check compared; make sure the bundle that
        // actually ships inside the image agrees before it replaces anything.
        guard version.numbers == expected.numbers else {
            throw ManagerError.verificationFailed(
                "릴리스는 \(expected)인데 이미지 안의 앱은 \(version)입니다."
            )
        }
        guard version > currentVersion else {
            throw ManagerError.verificationFailed(
                "설치된 \(currentVersion)보다 새롭지 않습니다: \(version)"
            )
        }
    }

    private func attach(image: URL) async throws -> String {
        let result = await runner.run(CommandSpec(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-noautoopen", image.path],
            timeout: 180
        ))
        guard result.succeeded, let mountPoint = Self.mountPoint(fromAttachOutput: result.output) else {
            throw ManagerError.commandFailed("디스크 이미지 마운트", result.exitCode, result.output)
        }
        return mountPoint
    }

    private func detach(mountPoint: String) async {
        _ = await runner.run(CommandSpec(
            executable: "/usr/bin/hdiutil",
            arguments: ["detach", mountPoint, "-quiet"],
            timeout: 60
        ))
    }

    private func locateApp(inside mountPoint: String) throws -> String {
        let contents = (try? fileManager.contentsOfDirectory(atPath: mountPoint)) ?? []
        guard let name = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw ManagerError.verificationFailed("디스크 이미지에서 앱을 찾지 못했습니다.")
        }
        return URL(fileURLWithPath: mountPoint).appendingPathComponent(name).path
    }

    static func teamIdentifier(fromCodesignOutput output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(trimmed.dropFirst("TeamIdentifier=".count))
            return value == "not set" ? nil : value
        }
        return nil
    }

    static func isNotarized(spctlOutput output: String) -> Bool {
        let lines = output.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // Gatekeeper reports the verdict and the reason on separate lines; an
        // accepted-but-unnotarized image says "source=Unnotarized Developer ID".
        let accepted = lines.contains { $0.hasSuffix(": accepted") || $0 == "accepted" }
        let notarized = lines.contains { $0 == "source=Notarized Developer ID" }
        return accepted && notarized
    }

    static func mountPoint(fromAttachOutput output: String) -> String? {
        for line in output.components(separatedBy: .newlines).reversed() {
            guard let range = line.range(of: "/Volumes/") else { continue }
            let path = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                return path
            }
        }
        return nil
    }
}
