import SwiftUI

struct WorkspaceArchiveUndoItem: Identifiable, Equatable {
    let id: String
    let title: String
    let projectID: String
    let sourceTreeID: String
}

/// A persistent, dismissible receipt: users can undo after closing the cleanup sheet.
struct WorkspaceArchiveUndoView: View {
    @ObservedObject var model: WorkspaceViewModel

    var body: some View {
        if !model.archiveUndoItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Label("\(model.archiveUndoItems.count)개 작업을 보관했습니다", systemImage: "archivebox")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if model.isUndoingArchive {
                        ProgressView().controlSize(.small)
                    }
                    Button("실행 취소") { Task { await model.undoLastArchive() } }
                        .disabled(model.isUndoingArchive || model.isCleaningSessions || model.isMutatingWorkspace)
                    Button { model.dismissArchiveUndo() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("알림 닫기 · 보관함에서 나중에 복원할 수 있습니다")
                    .accessibilityLabel("보관 알림 닫기")
                    .disabled(model.isUndoingArchive)
                }
                if let error = model.archiveUndoError {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .help(error)
                        .textSelection(.enabled)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(WorkspacePalette.chromeBackground)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("작업 보관 결과")
        }
    }
}
