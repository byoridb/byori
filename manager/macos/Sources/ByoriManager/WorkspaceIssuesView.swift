import AppKit
import ByoriManagerCore
import SwiftUI

/// The Issues inspector tab (#22): the project's GitHub issues, read and
/// changed through the user's own gh, with a way to start a session on one.
///
/// The inspector is narrow, so the list and an issue take turns rather than
/// sharing the width: selecting an issue replaces the list, and "목록" brings
/// it back where it was.
struct WorkspaceIssuesView: View {
    @StateObject private var model: WorkspaceIssuesViewModel
    let startWork: (GitHubIssueSummary) -> Void

    init(
        makeProvider: @escaping () async throws -> any GitHubIssueProviding,
        startWork: @escaping (GitHubIssueSummary) -> Void
    ) {
        _model = StateObject(wrappedValue: WorkspaceIssuesViewModel(makeProvider: makeProvider))
        self.startWork = startWork
    }

    var body: some View {
        Group {
            if model.selectedNumber != nil {
                WorkspaceIssueDetailView(model: model, startWork: startWork)
            } else {
                listContent
            }
        }
        .task { await model.loadIfNeeded() }
        .sheet(isPresented: $model.isPresentingNewIssue) {
            WorkspaceNewIssueSheet(model: model)
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("이슈 상태", selection: Binding(get: { model.filter }, set: { model.setFilter($0) })) {
                    ForEach(GitHubIssueListFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 6) {
                    TextField("검색", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.reloadList() } }
                    Button { model.prepareNewIssue() } label: { Image(systemName: "plus") }
                        .help("새 이슈")
                        .disabled(model.repository == nil)
                    Button { Task { await model.reloadList() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("새로 고침")
                        .disabled(model.listPhase == .loading)
                }
                .controlSize(.small)

                if let repository = model.repository {
                    Text(repository)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(12)

            Divider()

            listBody
        }
    }

    @ViewBuilder
    private var listBody: some View {
        switch model.listPhase {
        case .idle, .loading:
            WorkspaceUnavailableView(
                icon: "record.circle",
                title: "이슈를 불러오는 중",
                detail: "gh로 GitHub 이슈를 읽고 있습니다.",
                showsProgress: true
            )
        case let .failed(message):
            WorkspaceUnavailableView(
                icon: "exclamationmark.triangle",
                title: "이슈를 표시할 수 없습니다",
                detail: message,
                primaryTitle: "다시 시도",
                primaryAction: { Task { await model.reloadList() } }
            )
        case .ready:
            if model.issues.isEmpty {
                WorkspaceUnavailableView(
                    icon: "checkmark.circle",
                    title: "표시할 이슈가 없습니다",
                    detail: model.search.isEmpty
                        ? "\(model.filter.title) 상태의 이슈가 없습니다."
                        : "검색과 일치하는 이슈가 없습니다."
                )
            } else {
                List(model.issues) { issue in
                    Button { Task { await model.select(issue.number) } } label: {
                        WorkspaceIssueRow(issue: issue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .accessibilityLabel("GitHub issues")
                if model.issues.count >= GitHubIssueService.listLimit {
                    Text("최근 \(GitHubIssueService.listLimit)개만 표시합니다. 검색으로 범위를 좁히세요.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
    }
}

private struct WorkspaceIssueRow: View {
    let issue: GitHubIssueSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            WorkspaceIssueStateIcon(state: issue.state, reason: issue.stateReason)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text("#\(issue.number)")
                        .font(.caption.monospacedDigit())
                    if let updatedAt = issue.updatedAt {
                        Text("· \(WorkspaceIssueDates.relative(updatedAt))")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                if !issue.labels.isEmpty {
                    WorkspaceIssueLabels(labels: issue.labels)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceIssueDetailView: View {
    @ObservedObject var model: WorkspaceIssuesViewModel
    let startWork: (GitHubIssueSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.showList() } label: { Label("목록", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                if let url = model.detail?.url {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless)
                        .help("GitHub에서 열기")
                }
                Button { Task { await model.reloadDetail() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("새로 고침")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            Divider()

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let detail = model.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(detail)
                    actions(detail.summary)
                    if let error = model.actionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    metadata(detail.summary)
                    Divider()
                    WorkspaceIssueMarkdown(text: detail.body.isEmpty ? "_본문 없음_" : detail.body)
                    Divider()
                    comments(detail.comments)
                    composer
                }
                .padding(12)
                .disabled(model.isWorking)
            }
        } else if case let .failed(message) = model.detailPhase {
            WorkspaceUnavailableView(
                icon: "exclamationmark.triangle",
                title: "이슈를 읽지 못했습니다",
                detail: message,
                primaryTitle: "다시 시도",
                primaryAction: { Task { await model.reloadDetail() } }
            )
        } else {
            WorkspaceUnavailableView(
                icon: "record.circle",
                title: "이슈를 불러오는 중",
                detail: "본문과 댓글을 읽고 있습니다.",
                showsProgress: true
            )
        }
    }

    private func header(_ detail: GitHubIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.summary.title)
                .font(.headline)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                WorkspaceIssueStateIcon(state: detail.summary.state, reason: detail.summary.stateReason)
                Text(stateText(detail.summary))
                Text("#\(detail.summary.number)").monospacedDigit()
                if let author = detail.summary.author {
                    Text("· \(author)")
                }
                if let createdAt = detail.createdAt {
                    Text("· \(WorkspaceIssueDates.relative(createdAt))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func actions(_ issue: GitHubIssueSummary) -> some View {
        HStack(spacing: 8) {
            Button { startWork(issue) } label: {
                Label("이 이슈로 작업 시작", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("이 이슈 이름으로 새 작업과 세션을 준비합니다.")

            if issue.state == .open {
                Menu("닫기") {
                    ForEach(GitHubIssueCloseReason.allCases) { reason in
                        Button(reason.title) { Task { await model.close(reason: reason) } }
                    }
                }
                .fixedSize()
            } else {
                Button("다시 열기") { Task { await model.reopen() } }
            }
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .controlSize(.small)
    }

    private func metadata(_ issue: GitHubIssueSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("라벨").font(.caption.weight(.semibold)).frame(width: 44, alignment: .leading)
                if issue.labels.isEmpty {
                    Text("없음").font(.caption).foregroundStyle(.secondary)
                } else {
                    WorkspaceIssueLabels(labels: issue.labels)
                }
                Spacer(minLength: 4)
                Menu {
                    if model.availableLabels.isEmpty {
                        Text("라벨 목록을 불러오지 못했습니다")
                    }
                    ForEach(model.availableLabels) { label in
                        Toggle(label.name, isOn: Binding(
                            get: { issue.labels.contains { $0.name == label.name } },
                            set: { _ in Task { await model.toggleLabel(label.name) } }
                        ))
                    }
                } label: { Image(systemName: "pencil") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("라벨 편집")
            }
            HStack(alignment: .firstTextBaseline) {
                Text("담당자").font(.caption.weight(.semibold)).frame(width: 44, alignment: .leading)
                Text(issue.assignees.isEmpty ? "없음" : issue.assignees.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(issue.assignees.isEmpty ? .secondary : .primary)
                Spacer(minLength: 4)
                Menu {
                    if model.assignableUsers.isEmpty {
                        Text("담당자 목록을 불러오지 못했습니다")
                    }
                    ForEach(model.assignableUsers, id: \.self) { login in
                        Toggle(login, isOn: Binding(
                            get: { issue.assignees.contains(login) },
                            set: { _ in Task { await model.toggleAssignee(login) } }
                        ))
                    }
                } label: { Image(systemName: "pencil") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("담당자 편집")
            }
        }
        .buttonStyle(.borderless)
    }

    private func comments(_ comments: [GitHubIssueComment]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(comments.isEmpty ? "댓글 없음" : "댓글 \(comments.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(comment.author ?? "알 수 없음").font(.caption.weight(.semibold))
                        if let createdAt = comment.createdAt {
                            Text("· \(WorkspaceIssueDates.relative(createdAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    WorkspaceIssueMarkdown(text: comment.body)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $model.commentDraft)
                .font(.callout)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel("새 댓글")
            Button("댓글 달기") { Task { await model.postComment() } }
                .controlSize(.small)
                .disabled(model.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func stateText(_ issue: GitHubIssueSummary) -> String {
        switch (issue.state, issue.stateReason) {
        case (.open, _): return "열림"
        case (.closed, "NOT_PLANNED"): return "닫힘 · 계획 안 함"
        case (.closed, _): return "닫힘 · 완료"
        }
    }
}

private struct WorkspaceNewIssueSheet: View {
    @ObservedObject var model: WorkspaceIssuesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("새 이슈").font(.headline)
            if let repository = model.repository {
                Text(repository).font(.caption).foregroundStyle(.secondary)
            }
            TextField("제목", text: $model.newIssueTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $model.newIssueBody)
                .font(.callout)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel("본문")
            Text("본문은 Markdown으로 작성합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = model.newIssueError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("취소", role: .cancel) { model.isPresentingNewIssue = false }
                    .keyboardShortcut(.cancelAction)
                Button("등록") { Task { await model.createIssue() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreateIssue)
            }
        }
        .padding(20)
        .frame(width: 480)
        .disabled(model.isWorking)
    }
}

private struct WorkspaceIssueStateIcon: View {
    let state: GitHubIssueState
    let reason: String?

    var body: some View {
        Image(systemName: icon)
            .foregroundStyle(color)
            .accessibilityLabel(state == .open ? "열림" : "닫힘")
    }

    private var icon: String {
        switch (state, reason) {
        case (.open, _): return "smallcircle.filled.circle"
        case (.closed, "NOT_PLANNED"): return "slash.circle"
        case (.closed, _): return "checkmark.circle"
        }
    }

    private var color: Color {
        switch (state, reason) {
        case (.open, _): return .green
        case (.closed, "NOT_PLANNED"): return .secondary
        case (.closed, _): return .purple
        }
    }
}

private struct WorkspaceIssueLabels: View {
    let labels: [GitHubLabel]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels.prefix(3)) { label in
                Text(label.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color(label).opacity(0.25), in: Capsule())
                    .overlay(Capsule().stroke(color(label).opacity(0.6)))
            }
            if labels.count > 3 {
                Text("+\(labels.count - 3)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ label: GitHubLabel) -> Color {
        guard label.color.count == 6, let value = Int(label.color, radix: 16) else { return .secondary }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Inline Markdown with the line breaks kept. Block syntax (headings, lists,
/// tables, HTML) shows as its source text, which stays readable; the full
/// rendering is one click away on GitHub.
private struct WorkspaceIssueMarkdown: View {
    let text: String

    var body: some View {
        Text(attributed)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private enum WorkspaceIssueDates {
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
