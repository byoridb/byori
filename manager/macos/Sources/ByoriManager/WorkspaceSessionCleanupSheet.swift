import SwiftUI

/// Cleanup archives complete inactive tasks so their otherwise empty outline
/// rows disappear while session history and task sidecars remain recoverable.
struct WorkspaceSessionCleanupSheet: View {
    @ObservedObject var model: WorkspaceViewModel
    @State private var showsArchive = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("지난 세션 정리").font(.title2.weight(.semibold))
                Text("세션이 모두 종료된 작업을 보관해 목록을 줄입니다. 보관함에서 다시 복원할 수 있습니다.")
                    .foregroundStyle(.secondary)
                Text("프로젝트 파일·브랜치·워크트리는 그대로 유지됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Picker("보기", selection: $showsArchive) {
                    Text("정리 대상").tag(false)
                    Text("보관함").tag(true)
                }
                .pickerStyle(.segmented)

                HStack {
                    Picker("프로젝트", selection: $model.cleanupProjectID) {
                        Text("모든 프로젝트").tag(String?.none)
                        ForEach(model.cleanupProjects) { project in
                            Text(project.name).tag(String?.some(project.id))
                        }
                    }
                    .onChange(of: model.cleanupProjectID) { _ in
                        Task { await model.refreshSessionCleanup() }
                    }
                    if !showsArchive {
                        Picker("종료 기록", selection: $model.cleanupThreshold) {
                            ForEach(WorkspaceCleanupThreshold.allCases) { threshold in
                                Text(threshold.label).tag(threshold)
                            }
                        }
                    }
                }

                if !showsArchive {
                    Text("가장 최근 세션의 종료 시각을 기준으로 합니다. 실행 중인 세션이 있는 작업 \(model.cleanupActiveExclusionCount)개는 제외했습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.cleanupActiveListIsTruncated {
                        Label("작업 기록의 일부만 불러왔습니다. 표시된 항목만 정리할 수 있습니다.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.cleanupArchiveListIsTruncated {
                    Label("보관함의 일부 기록만 불러왔습니다.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Text(showsArchive ? "보관한 작업 \(model.archivedCleanupTasks.count)개" : "정리할 작업 \(model.cleanupCandidates.count)개")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("모두 선택") { selectAll() }
                        .disabled(selectableIDs.isEmpty)
                    Button("선택 해제") { clearSelection() }
                        .disabled(selectedCount == 0)
                    Button {
                        Task { await model.refreshSessionCleanup() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("정리 목록 새로고침")
                    .accessibilityLabel("정리 목록 새로고침")
                }
            }
            .padding(20)
            .disabled(model.isCleaningSessions)

            Divider()

            cleanupList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(model.isCleaningSessions)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let message = model.cleanupResultSummary {
                    Text(message).font(.callout).textSelection(.enabled)
                }
                if let error = model.cleanupError {
                    ScrollView {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                    .accessibilityLabel("정리하지 못한 항목")
                }
                HStack {
                    if model.isCleaningSessions {
                        ProgressView().controlSize(.small)
                        Text("기록을 정리하고 있습니다…").font(.caption)
                    } else {
                        Text("\(selectedCount)개 선택됨").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("닫기") { model.dismissSessionCleanup() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isCleaningSessions)
                    Button(showsArchive ? "선택한 \(selectedCount)개 복원" : "선택한 \(selectedCount)개 보관") {
                        Task {
                            if showsArchive {
                                await model.restoreSelectedCleanupTasks()
                            } else {
                                await model.archiveSelectedCleanupTasks()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCount == 0 || model.isCleaningSessions || !listIsReady)
                }
            }
            .padding(16)
        }
        .frame(width: 700)
        .frame(minHeight: 520, idealHeight: 640)
        .interactiveDismissDisabled(model.isCleaningSessions)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("지난 세션 정리 및 복원")
    }

    @ViewBuilder
    private var cleanupList: some View {
        switch showsArchive ? model.cleanupArchivedPhase : model.cleanupPhase {
        case .idle, .loading:
            ProgressView("작업 기록을 불러오고 있습니다…")
        case let .failed(message):
            VStack(spacing: 10) {
                Text(message).foregroundStyle(.secondary)
                Button("다시 불러오기") { Task { await model.refreshSessionCleanup() } }
            }
            .padding(20)
        case .ready:
            if showsArchive {
                if model.archivedCleanupTasks.isEmpty {
                    emptyState(
                        model.cleanupArchiveListIsTruncated ? "불러온 범위에 보관한 작업이 없습니다" : "보관한 작업이 없습니다",
                        detail: "보관한 작업과 세션 기록이 여기에 표시됩니다."
                    )
                } else {
                    List(model.archivedCleanupTasks) { item in
                        Toggle(isOn: archiveSelection(for: item.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                rowTitle(item.title, project: item.projectName, count: item.sessionCount, ended: item.latestEndedAt)
                                if let reason = item.restoreUnavailableReason {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(item.restoreUnavailableReason != nil)
                    }
                    .listStyle(.inset)
                }
            } else if model.cleanupCandidates.isEmpty {
                emptyState(
                    model.cleanupActiveListIsTruncated ? "불러온 범위에 이 조건의 작업이 없습니다" : "이 조건에 맞는 작업이 없습니다",
                    detail: "다른 기간이나 프로젝트를 선택해 보세요."
                )
            } else {
                List(model.cleanupCandidates) { item in
                    Toggle(isOn: cleanupSelection(for: item.id)) {
                        rowTitle(item.title, project: item.projectName, count: item.sessionCount, ended: item.latestEndedAt)
                            .padding(.vertical, 5)
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.inset)
            }
        }
    }

    private func rowTitle(_ title: String, project: String, count: Int, ended: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium)).lineLimit(2)
            Text("\(project) · 세션 \(count)개")
                .font(.caption).foregroundStyle(.secondary)
            Text(ended.map { "최근 종료 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "종료 시각 없음")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "archivebox").font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private var listIsReady: Bool {
        if case .ready = showsArchive ? model.cleanupArchivedPhase : model.cleanupPhase { return true }
        return false
    }

    private var selectableIDs: Set<String> {
        showsArchive
            ? Set(model.archivedCleanupTasks.filter { $0.restoreUnavailableReason == nil }.map(\.id))
            : Set(model.cleanupCandidates.map(\.id))
    }

    private var selectedCount: Int {
        (showsArchive ? model.selectedArchivedTaskIDs : model.selectedCleanupTaskIDs).intersection(selectableIDs).count
    }

    private func selectAll() {
        if showsArchive { model.selectedArchivedTaskIDs = selectableIDs }
        else { model.selectedCleanupTaskIDs = selectableIDs }
    }

    private func clearSelection() {
        if showsArchive { model.selectedArchivedTaskIDs = [] }
        else { model.selectedCleanupTaskIDs = [] }
    }

    private func cleanupSelection(for id: String) -> Binding<Bool> {
        Binding(get: { model.selectedCleanupTaskIDs.contains(id) }, set: { selected in
            if selected { model.selectedCleanupTaskIDs.insert(id) }
            else { model.selectedCleanupTaskIDs.remove(id) }
        })
    }

    private func archiveSelection(for id: String) -> Binding<Bool> {
        Binding(get: { model.selectedArchivedTaskIDs.contains(id) }, set: { selected in
            if selected { model.selectedArchivedTaskIDs.insert(id) }
            else { model.selectedArchivedTaskIDs.remove(id) }
        })
    }
}
