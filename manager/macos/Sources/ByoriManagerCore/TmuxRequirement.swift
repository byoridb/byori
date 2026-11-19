import Foundation

/// How Byori installs tmux, when it can.
///
/// Homebrew only. tmux publishes no official macOS installer, and compiling it
/// from source is not something a Settings button should start on someone's
/// behalf. When brew is absent Byori states the requirement instead of offering
/// an action whose only possible outcome is a failure.
public enum TmuxInstallMethod: Equatable, Sendable {
    case homebrew(executablePath: String)

    public var executablePath: String {
        switch self {
        case let .homebrew(path): return path
        }
    }
}

/// What Settings can report and act on for tmux.
///
/// tmux earns a place in Settings for exactly one reason: without it every
/// session ends when Byori quits. That was already said in the new-session
/// sheet — with nothing the user could do about it — which is the gap this
/// status closes.
public struct TmuxStatus: Equatable, Sendable {
    public let availability: TmuxAvailability
    public let install: TmuxInstallMethod?
    /// Homebrew has no bottle for this Mac, so `brew install tmux` would compile
    /// tmux and its dependencies — and their build tools — from source (#70).
    public let homebrewBuildsFromSource: Bool

    public init(
        availability: TmuxAvailability,
        install: TmuxInstallMethod?,
        homebrewBuildsFromSource: Bool = false
    ) {
        self.availability = availability
        self.install = install
        self.homebrewBuildsFromSource = homebrewBuildsFromSource
    }

    public var isAvailable: Bool { availability.isAvailable }

    /// A source build is not offered either: it runs far past any timeout a
    /// Settings button can give it, and showing its progress is the terminal's
    /// job, not a spinner's.
    public var canInstall: Bool { install != nil && !homebrewBuildsFromSource }

    /// True when tmux is present but Byori will not use it. The fix is an
    /// upgrade, not a first install, and the two must not be described with the
    /// same word.
    public var needsUpgrade: Bool {
        switch availability {
        case .available, .unavailable(.notInstalled):
            return false
        case .unavailable:
            return true
        }
    }

    /// The bounded state text shown beside the requirement's name.
    public var stateLabel: String {
        switch availability {
        case let .available(_, version):
            return "tmux \(version) · 세션 유지 사용"
        case .unavailable(.notInstalled):
            return "미설치"
        case let .unavailable(.versionTooOld(found, required)):
            return "tmux \(found) · \(required) 이상 필요"
        case .unavailable(.unreadableVersion):
            return "버전 확인 실패"
        }
    }

    /// One sentence: the consequence, and what removes it.
    public var detail: String {
        switch availability {
        case .available:
            return "앱을 닫아도 세션이 tmux에 남아 다시 연결할 수 있습니다."
        case let .unavailable(reason):
            if install != nil, homebrewBuildsFromSource {
                return reason.message
                    + " Homebrew가 이 Mac용 tmux 바이너리를 제공하지 않아 소스에서 빌드해야 합니다."
                    + " 오래 걸리므로 터미널에서 brew \(installSubcommand) tmux를 직접 실행하세요."
            }
            guard canInstall else {
                return reason.message + " Homebrew가 없어 Byori가 직접 설치할 수 없습니다."
            }
            return reason.message
        }
    }

    /// The title of the single action that changes this state, or nil when there
    /// is nothing for Byori to do.
    public var actionTitle: String? {
        guard !isAvailable, canInstall else { return nil }
        return needsUpgrade ? "Homebrew로 업그레이드" : "Homebrew로 설치"
    }

    /// The brew subcommand that gets from this state to a usable tmux.
    ///
    /// The two are not interchangeable: `brew install` refuses a formula that is
    /// already installed and `brew upgrade` refuses one that is not, so picking
    /// the wrong one turns a working path into a reported failure.
    public var installSubcommand: String {
        needsUpgrade ? "upgrade" : "install"
    }
}

/// Reads `brew info --json=v2 <formula>` for whether Homebrew can pour a bottle
/// on this Mac.
///
/// Homebrew's API data is cut per platform: it carries only the bottle for the
/// running system's tag, so an empty `files` means a source build. Measured on
/// formulae.brew.sh for tmux 3.8: bottles exist for macOS 15+ on Apple Silicon
/// and for Linux only, and the arm64_ventura data has none.
enum HomebrewBottle {
    /// nil when the output is not the JSON expected; the caller then keeps the
    /// install it would have offered anyway.
    static func isPoured(infoOutput: String) -> Bool? {
        // Warnings on stderr (an old macOS, untrusted taps) share the output, so
        // the document is cut out by its own top-level braces.
        let lines = infoOutput.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "{"),
              let end = lines.lastIndex(of: "}"),
              start < end,
              let data = lines[start...end].joined(separator: "\n").data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formula = (document["formulae"] as? [[String: Any]])?.first
        else { return nil }
        let stable = (formula["bottle"] as? [String: Any])?["stable"] as? [String: Any]
        let files = stable?["files"] as? [String: Any] ?? [:]
        return !files.isEmpty
    }
}
