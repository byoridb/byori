import AppKit
import ByoriManagerCore
import SwiftUI

struct WorkspaceMemoryScope: Identifiable {
    let id = UUID()
    let projectID: String
    let sourceTreeID: String
    let taskID: String
    let title: String
    let path: String
    let record: MemoryRecord?
    init(project: WorkspaceProjectItem, tree: WorkspaceSourceTreeItem, task: WorkspaceTaskItem?, record: MemoryRecord?) {
        projectID = project.id; sourceTreeID = tree.id; taskID = task?.id ?? "project"
        title = "\(project.name) · \(tree.name) · \(task?.title ?? "프로젝트")"
        path = tree.url.path; self.record = record
    }
}

struct WorkspaceMemoryChange: Sendable {
    var archived: Bool? = nil
    var pinned: Bool? = nil
    var reviewAfter: Int64? = nil
    var sourcePath: String? = nil
    var verifySource = false
}

struct WorkspaceMemorySheet: View {
    @ObservedObject var workspace: WorkspaceViewModel
    let scope: WorkspaceMemoryScope
    @State private var resume: TaskResume?
    @State private var draft = TaskCheckpointDraft()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?
    @State private var notice: String?
    @State private var sourcePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scope.record == nil ? "작업 체크포인트" : "기억 관리").font(.title3.weight(.semibold))
                    Text(scope.title).font(.callout)
                    Text(scope.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기", action: workspace.dismissMemory).keyboardShortcut(.cancelAction).disabled(isSaving)
            }.padding(20)
            Divider()
            if isLoading {
                ProgressView("기억을 불러오는 중").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let record = scope.record { policy(record) } else { checkpoint }
                        if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        if let notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(20)
                }
            }
            Divider()
            if scope.record == nil {
                HStack {
                    Button("다시 불러오기") { Task { await load() } }.disabled(isSaving || isLoading)
                    Button("저장된 내용 복사") { copyCheckpoint() }.disabled(resume?.checkpoint == nil || isSaving)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                    Button("체크포인트 저장") { Task { await save() } }
                        .disabled(isLoading || isSaving || draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(16)
            }
        }
        .frame(minWidth: 680, idealWidth: 780, minHeight: 560, idealHeight: 720)
        .interactiveDismissDisabled(isSaving)
        .task { sourcePath = scope.record?.policy.source?.path ?? ""; await load() }
    }

    private var checkpoint: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let saved = resume?.checkpoint {
                Text("저장 시각: \(Date(timeIntervalSince1970: Double(saved.createdAt) / 1000).formatted())")
                    .font(.caption).foregroundStyle(.secondary)
                Text("기준 revision: \(saved.revision.isEmpty ? "미확인" : String(saved.revision.prefix(12)))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(resume?.revisionState == "match"
                     ? "기준 커밋과 같습니다. 저장 이후 작업 트리 변경 및 검증 결과는 확인해 주세요."
                     : "기준 커밋이 달라졌거나 확인되지 않았습니다. 현재 코드와 대조해 이어가세요.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("저장된 체크포인트가 없습니다. 이 작업의 현재 상태를 남겨 다음 세션에서 이어갈 수 있습니다.")
                    .foregroundStyle(.secondary)
            }
            checkpointField("목표", text: $draft.goal)
            checkpointField("확정한 결정", text: $draft.decisions)
            checkpointField("시도와 결과", text: $draft.attempts)
            checkpointField("검증 상태", text: $draft.verification)
            checkpointField("다음 작업", text: $draft.nextSteps)
            Text("명시적으로 작성한 작업 상태만 저장합니다. 복사한 내용은 실행되지 않으며, 이어갈 에이전트에서 검토해 사용하세요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkpointField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            TextEditor(text: text).font(.body).frame(minHeight: 65).border(Color.secondary.opacity(0.25))
                .accessibilityLabel(title)
        }
    }

    private func policy(_ record: MemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(record.name).font(.headline).textSelection(.enabled)
            Text(record.body).textSelection(.enabled)
            if record.bodyTruncated == true {
                Text("긴 본문의 일부만 표시합니다. 전체 내용은 MCP에서 이 기억의 유형·이름과 view=all을 지정해 조회할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("현재 분류: \(MemoryView(rawValue: record.lifecycle)?.title ?? record.lifecycle)")
                .font(.caption).foregroundStyle(.secondary)
            if !record.reviewReasons.isEmpty {
                Text(record.reviewReasonLabels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(record.policy.archived ? "보관 해제" : "보관함으로 이동") {
                    apply(.init(archived: !record.policy.archived))
                }
                Button(record.policy.pinned ? "중요 표시 해제" : "중요 기억 표시") {
                    apply(.init(pinned: !record.policy.pinned))
                }
                Button("30일 후 재검토") {
                    apply(.init(reviewAfter: Int64(Date().addingTimeInterval(30 * 86400).timeIntervalSince1970 * 1000)))
                }
            }.disabled(isSaving)
            Text("보관은 기본 조회에서 제외하며 원본을 유지합니다. 중요 표시는 조회 순서를 바꾸지 않습니다. 대체된 결정은 보관을 해제하거나 중요 표시를 해도 현재 기억으로 취급하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("근거 파일").font(.headline)
            TextField("작업 트리 안의 상대 경로", text: $sourcePath).textFieldStyle(.roundedBorder)
            Button("현재 파일을 근거로 연결") {
                apply(.init(sourcePath: sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)))
            }.disabled(isSaving || sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("현재 파일의 내용을 확인한 뒤 연결하세요. 이후 파일이 달라지면 재검토 대상으로 표시합니다. 파일 일치 여부는 기억 내용의 타당성과 별도로 확인합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard scope.record == nil else { isLoading = false; return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let loaded = try await workspace.resumeCheckpoint(scope: scope)
            guard !Task.isCancelled else { return }
            resume = loaded
            draft = loaded.checkpoint?.draft ?? TaskCheckpointDraft()
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true; error = nil; notice = nil
        defer { isSaving = false }
        do {
            try await workspace.saveCheckpoint(scope: scope, draft: draft)
            await load()
            notice = "이 작업의 체크포인트를 저장했습니다."
        } catch { self.error = error.localizedDescription }
    }

    private func apply(_ change: WorkspaceMemoryChange) {
        guard !isSaving else { return }
        isSaving = true; error = nil
        Task {
            defer { isSaving = false }
            do {
                try await workspace.updateMemoryPolicy(scope: scope, change: change)
                workspace.dismissMemory()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func copyCheckpoint() {
        guard let saved = resume?.checkpoint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("작업: \(scope.title)\n기준 revision: \(saved.revision)\n\n" + saved.draft.text, forType: .string)
        notice = "저장된 내용을 복사했습니다. 현재 코드와 검증 결과를 확인하고 이어가세요."
    }
}
