import AppKit
import ByoriManagerCore
import SwiftUI

struct WorkspaceSessionPane<TerminalHost: View>: View {
    let project: WorkspaceProjectItem
    let sourceTree: WorkspaceSourceTreeItem
    let task: WorkspaceTaskItem
    let session: WorkspaceSessionItem
    let isStopping: Bool
    let isReattaching: Bool
    let stop: () -> Void
    let reattach: () -> Void
    let newSession: () -> Void
    let showTaskWork: () -> Void
    let newTerminal: () -> Void
    let commandGroups: [AgentCommandGroup]
    let insertTerminalText: (String) -> Void
    let terminalHost: (WorkspaceSessionItem) -> TerminalHost

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            Divider()
            terminalContent
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: 12) {
            // Only show the branch when the full title still fits. The fallback
            // gives long project/task names the space that remains after actions.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    sessionTitle
                    Text(sourceTree.branch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120)
                        .help(checkoutHelp)
                }
                .fixedSize(horizontal: true, vertical: false)

                sessionTitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                sessionStatus
                    .padding(.trailing, 4)
                sessionActions
                sessionMenu
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(WorkspacePalette.chromeBackground)
    }

    private var sessionTitle: some View {
        HStack(spacing: 6) {
            Text(project.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 64, maxWidth: 120, alignment: .leading)
                .help(project.name)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(task.title)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help("\(task.title)\n세션: \(session.displayName)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name), \(task.title), \(session.displayName)")
    }

    @ViewBuilder
    private var sessionActions: some View {
        if session.isDetached {
            Button(action: reattach) {
                if isReattaching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Label("다시 연결", systemImage: "arrow.uturn.backward.circle")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 26, height: 26)
            .disabled(isReattaching)
            .help(isReattaching ? "세션에 연결하는 중입니다" : "tmux에서 실행 중인 세션에 다시 연결")
            .accessibilityLabel(isReattaching ? "Reattaching session" : "Reattach session")
        }

        if session.isDetached || session.state.isActive {
            Button(action: stop) {
                if isStopping {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Label("Stop", systemImage: "stop.circle")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 26, height: 26)
            .keyboardShortcut(".", modifiers: .command)
            .disabled(isStopping)
            .help(isStopping ? "세션을 중지하는 중입니다" : "Stop Session (⌘.)")
            .accessibilityLabel(isStopping ? "Stopping session" : "Stop session")

            if !session.isDetached {
                // Reopening selects this checkout's shell without displacing
                // or stopping the agent process.
                Button(action: newTerminal) {
                    Label("터미널", systemImage: "apple.terminal")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: 26, height: 26)
                .help("같은 체크아웃에서 셸 열기")
                .accessibilityLabel("Open a shell in this checkout")
            }
        } else {
            Button(action: newSession) {
                Label("New Session", systemImage: "plus.rectangle.on.rectangle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 26, height: 26)
            .help("Start another session for \(task.title)")
            .accessibilityLabel("New session for task \(task.title)")
            .accessibilityHint("Opens session setup for this task and keeps the ended session in history")
        }
    }

    private var sessionMenu: some View {
        Menu {
            Button(action: showTaskWork) {
                Label("작업 절차·검증", systemImage: "checklist")
            }
            if !commandGroups.isEmpty {
                commandMenu
            }

            Divider()
            Text("세션: \(session.displayName)")
            Text("브랜치: \(sourceTree.branch)")
            Text("체크아웃: \(sourceTree.name) · \(sourceTree.kind.label)")
            Text(sourceTree.url.path)
            Divider()
            Text("시작할 때 선택: \(session.launchSelectionDisplayName)")
            Text("터미널에서 바꾼 선택은 에이전트가 관리합니다")
        } label: {
            Label("세션 메뉴", systemImage: "ellipsis")
                .frame(width: 26, height: 26)
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("세션 정보, 명령 삽입 및 작업 절차·검증")
        .accessibilityLabel("Session actions and details")
    }

    private var commandMenu: some View {
        Menu {
            ForEach(commandGroups) { group in
                Menu {
                    ForEach(group.commands) { command in
                        Button(command.title) {
                            // Insert editable text only; no Return or submit.
                            insertTerminalText(command.insertion)
                        }
                    }
                } label: {
                    Label(
                        group.name,
                        systemImage: group.source == .plugin
                            ? "puzzlepiece.extension" : "wand.and.stars"
                    )
                }
            }
        } label: {
            Label("명령 삽입", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .disabled(!canInsertCommands)
        .help(commandMenuHelp)
        .accessibilityHint("Inserts the selected command without running it")
    }

    @ViewBuilder
    private var terminalContent: some View {
        if session.isDetached {
            // The CLI is running, but under the tmux server rather than this
            // app, so there is no terminal view to mount until it reattaches.
            detachedSessionView
        } else {
            // TerminalSessionController retains SwiftTerm after process exit.
            // Keep that final buffer visible; historical sessions without a
            // retained view render ContentView's TerminalUnavailableView.
            terminalHost(session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WorkspacePalette.terminalBackground)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(terminalAccessibilityLabel)
                .accessibilityHint("Byori keeps the original launch selection; changes made inside the provider terminal are provider-controlled")
        }
    }

    /// Shown only while the automatic reattach is in flight, or after it failed.
    /// Selecting a session attaches it, so the button here is a fallback for the
    /// case where the CLI is gone and the error is worth seeing — not the normal
    /// way back into a session.
    private var detachedSessionView: some View {
        VStack(spacing: 12) {
            if isReattaching {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityHidden(true)
                Text("세션에 연결하는 중입니다")
                    .font(.title3.weight(.semibold))
                Text("Byori를 닫는 동안에도 이 CLI는 tmux에서 실행되고 있었습니다. 중단된 지점 그대로 이어집니다.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            } else {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("세션이 계속 실행 중입니다")
                    .font(.title3.weight(.semibold))
                Text("이 CLI는 tmux에서 실행되고 있었지만 자동 연결이 되지 않았습니다. 다시 연결하면 중단된 지점 그대로 이어집니다.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                Button(action: reattach) {
                    Label("세션에 다시 연결", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
                .accessibilityLabel("Reattach to session \(session.displayName)")
                .accessibilityHint("Reopens the terminal for the CLI still running in tmux")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspacePalette.terminalBackground)
    }

    private var checkoutHelp: String {
        "\(sourceTree.branch)\n\(sourceTree.name) · \(sourceTree.kind.label)\n\(sourceTree.url.path)"
    }

    private var terminalAccessibilityLabel: String {
        guard session.hasCustomName else {
            return "Interactive terminal for \(session.displayName)"
        }
        return "Interactive terminal for \(session.displayName), launched with \(session.launchSelectionDisplayName)"
    }

    private var sessionStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(WorkspacePalette.statusColor(session.state))
                .frame(width: 7, height: 7)
            Text(session.state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(sessionStatusHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sessionStatusHelp)
    }

    private var sessionStatusHelp: String {
        var details = ["Session status: \(session.state.label)"]
        if isStopping {
            details.append("세션을 중지하는 중입니다")
        } else if session.isDetached {
            details.append(isReattaching ? "세션에 연결하는 중입니다" : "CLI는 tmux에서 계속 실행 중입니다")
        }
        if let detail = session.statusDetail, !detail.isEmpty {
            details.append(detail)
        }
        return details.joined(separator: "\n")
    }

    private var commandMenuHelp: String {
        if session.isDetached { return "Reattach this session before inserting a command" }
        if session.state == .preparing { return "Wait for the terminal to finish starting" }
        if !canInsertCommands { return "Commands can only be inserted into a running session" }
        return "Insert a Skill or plugin command into the terminal"
    }

    private var canInsertCommands: Bool {
        !session.isDetached && (session.state == .running || session.state == .waitingForUser)
    }
}

