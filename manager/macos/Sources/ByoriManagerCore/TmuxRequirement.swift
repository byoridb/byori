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

    public init(availability: TmuxAvailability, install: TmuxInstallMethod?) {
        self.availability = availability
        self.install = install
    }

    public var isAvailable: Bool { availability.isAvailable }

    public var canInstall: Bool { install != nil }

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
