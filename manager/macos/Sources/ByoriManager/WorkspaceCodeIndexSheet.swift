import AppKit
import ByoriManagerCore
import SwiftUI

/// Captured when the browser opens, so changing the outline selection cannot
/// redirect a query, reanalysis, or source read to another checkout.
struct WorkspaceCodeIndexScope: Identifiable, Equatable {
    let id = UUID()
    let projectID: String
    let projectName: String
    let sourceTreeID: String
    let sourceTreeName: String
    let root: URL
    let space: String

    init(project: WorkspaceProjectItem, sourceTree: WorkspaceSourceTreeItem) {
        projectID = project.id
        projectName = project.name
        sourceTreeID = sourceTree.id
        sourceTreeName = sourceTree.name
        root = sourceTree.url
        space = project.memorySpace
    }
}

@MainActor
final class WorkspaceCodeIndexProvider: CodeIndexProviding {
    private let dataSource: any WorkspaceDataSource
    private let scope: WorkspaceCodeIndexScope

    init(dataSource: any WorkspaceDataSource, scope: WorkspaceCodeIndexScope) {
        self.dataSource = dataSource
        self.scope = scope
    }

    func queryCodeIndex(
        _ request: CodeIndexRequest, projectRoot: URL, space: String
    ) async throws -> CodeIndexResponse {
        guard projectRoot.standardizedFileURL == scope.root.standardizedFileURL, space == scope.space else {
            throw WorkspaceAdapterError.invalidState("코드 인덱스의 프로젝트 범위가 바뀌었습니다. 창을 다시 열어 주세요.")
        }
        return try await dataSource.readCodeIndex(
            request, projectID: scope.projectID, sourceTreeID: scope.sourceTreeID
        )
    }
}

struct WorkspaceCodeIndexSheet: View {
    @ObservedObject var workspace: WorkspaceViewModel
    let scope: WorkspaceCodeIndexScope
    @StateObject private var model: CodeIndexViewModel
    @State private var source: SourceLocation?

    init(workspace: WorkspaceViewModel, scope: WorkspaceCodeIndexScope) {
        self.workspace = workspace
        self.scope = scope
        _model = StateObject(wrappedValue: CodeIndexViewModel(
            provider: workspace.codeIndexProvider(for: scope), projectRoot: scope.root, space: scope.space
        ))
    }

    var body: some View {
        CodeIndexView(
            model: model, projectName: scope.projectName, sourceTreeName: scope.sourceTreeName,
            onClose: workspace.dismissCodeIndex,
            onAnalyze: { try await workspace.analyzeCodeIndex(scope: scope) },
            onOpenSource: { path, line in source = SourceLocation(path: path, line: max(1, line)) }
        )
        .sheet(item: $source) { location in
            IndexedSourceSheet(path: location.path, line: location.line, read: {
                try await workspace.readIndexedSource(location.path, scope: scope)
            }, close: { source = nil })
        }
    }

    private struct SourceLocation: Identifiable {
        let id = UUID()
        let path: String
        let line: Int
    }
}

private struct IndexedSourceSheet: View {
    let path: String
    let line: Int
    let read: () async throws -> WorkspaceFileDocument
    let close: () -> Void
    @State private var document: WorkspaceFileDocument?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(path).font(.headline).textSelection(.enabled)
                    Text("분석 위치: \(line)행 · 현재 작업 트리의 파일")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기", action: close).keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let document {
                IndexedSourceText(text: document.text, line: line)
                    .accessibilityLabel("\(path) 소스 코드, \(line)행")
            } else if let failure {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text("소스를 열 수 없습니다").font(.headline)
                    Text(failure).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
            } else {
                ProgressView("소스를 읽고 있습니다")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text("현재 파일을 읽기 전용으로 표시합니다. 분석 이후 파일이 바뀌었다면 줄 위치가 다를 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 500, idealHeight: 620)
        .task {
            do { document = try await read() }
            catch { failure = error.localizedDescription }
        }
    }
}

/// Native text storage keeps a bounded large source file usable without making
/// a SwiftUI row for every line. Selection and copying remain standard macOS.
private struct IndexedSourceText: NSViewRepresentable {
    let text: String
    let line: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        let lines = text.components(separatedBy: "\n")
        let target = min(max(0, line - 1), max(0, lines.count - 1))
        let offset = lines.prefix(target).reduce(0) { $0 + $1.utf16.count + 1 }
        let length = lines.isEmpty ? 0 : lines[target].utf16.count
        let range = NSRange(location: offset, length: length)
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
    }
}
