import AppKit
import SwiftTerm
import SwiftUI

/// Mounts an app-retained terminal without owning its process lifetime.
/// `dismantleNSView` detaches the AppKit view but intentionally does not stop
/// the PTY, allowing the same session to be reattached after a window closes.
@MainActor
struct TerminalSessionHost: NSViewRepresentable {
    let sessionID: UUID
    @ObservedObject private var controller: TerminalSessionController
    private let focusOnAttach: Bool

    init(sessionID: UUID, focusOnAttach: Bool = true) {
        self.init(
            sessionID: sessionID,
            controller: TerminalSessionController.shared,
            focusOnAttach: focusOnAttach
        )
    }

    init(
        sessionID: UUID,
        controller: TerminalSessionController,
        focusOnAttach: Bool = true
    ) {
        self.sessionID = sessionID
        self.focusOnAttach = focusOnAttach
        _controller = ObservedObject(wrappedValue: controller)
    }

    func makeNSView(context: Context) -> TerminalMountView {
        TerminalMountView()
    }

    func updateNSView(_ nsView: TerminalMountView, context: Context) {
        nsView.mount(
            controller.terminalView(for: sessionID),
            focusOnAttach: focusOnAttach
        )
    }

    static func dismantleNSView(_ nsView: TerminalMountView, coordinator: ()) {
        nsView.unmount()
    }
}

final class TerminalMountView: NSView {
    private weak var mountedTerminal: LocalProcessTerminalView?
    private var requestedFocusForCurrentTerminal = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.067,
            blue: 0.075,
            alpha: 1
        ).cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel("Interactive agent terminal")
    }

    required init?(coder: NSCoder) {
        nil
    }

    func mount(_ terminal: LocalProcessTerminalView?, focusOnAttach: Bool) {
        if mountedTerminal === terminal, terminal?.superview === self {
            return
        }
        unmount()
        guard let terminal else { return }

        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        mountedTerminal = terminal

        guard focusOnAttach else { return }
        requestedFocusForCurrentTerminal = true
        DispatchQueue.main.async { [weak self, weak terminal] in
            guard let self,
                  self.requestedFocusForCurrentTerminal,
                  self.mountedTerminal === terminal,
                  terminal?.superview === self else { return }
            self.window?.makeFirstResponder(terminal)
        }
    }

    func unmount() {
        requestedFocusForCurrentTerminal = false
        if mountedTerminal?.superview === self {
            mountedTerminal?.removeFromSuperview()
        }
        mountedTerminal = nil
    }
}
