import ByoriManagerCore
import SwiftUI

/// A checkout-scoped, read-only browser opened from the Context inspector.
struct CodeIndexView: View {
    @ObservedObject var model: CodeIndexViewModel
    let projectName: String
    let sourceTreeName: String
    let onClose: () -> Void
    let onAnalyze: () async throws -> Void
    let onOpenSource: (String, Int) -> Void
    @State private var isAnalyzing = false
    @State private var analysisError: String?
    @State private var analysisTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot = model.snapshot { summary(snapshot) }
            if let message = analysisError {
                messageBar(message, isError: true)
            }
            if let message = model.snapshotNotice {
                messageBar(message)
            }
            content
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 600, idealHeight: 720)
        .task { await model.load() }
        .onDisappear {
            model.cancel()
            analysisTask?.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("코드 인덱스")
                    .font(.title3.weight(.semibold))
                Text("\(projectName) · \(sourceTreeName)")
                    .font(.callout)
                Text(model.projectRoot.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.projectRoot.path)
            }
            Spacer()
            Button {
                Task { await model.reload() }
            } label: {
                Label("새로고침", systemImage: "arrow.clockwise")
            }
            .help("ByoriDB에 저장된 분석 결과를 다시 읽습니다.")
            .disabled(model.isLoading || isAnalyzing)
            Button(action: analyze) {
                Label(isAnalyzing ? "분석 중…" : "이 작업 트리 분석", systemImage: "magnifyingglass")
            }
            .disabled(isAnalyzing || model.isLoading)
        }
        .padding(20)
    }

    private func summary(_ snapshot: CodeIndexSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            freshnessSummary
            HStack(spacing: 16) {
                Text("파일 \(snapshot.files.formatted())")
                Text("심볼 \(snapshot.symbols.formatted())")
                Text("확인된 참조 \(snapshot.resolvedReferences.formatted())")
                Text("미확인 참조 \(snapshot.unresolvedReferences.formatted())")
                    .foregroundStyle(snapshot.unresolvedReferences > 0 ? Color.orange : Color.secondary)
                Spacer(minLength: 0)
            }
            .font(.callout.monospacedDigit())

            HStack(spacing: 8) {
                Text("최근 분석")
                Text(Date(timeIntervalSince1970: Double(snapshot.indexedAt) / 1000), format: .dateTime.year().month().day().hour().minute())
                if !snapshot.revision.isEmpty {
                    Text("·")
                    Text(String(snapshot.revision.prefix(12))).monospaced()
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(snapshot.languages, id: \.self) { language in
                        if let count = snapshot.languageStats?[language] {
                            Text("\(languageName(language)) \(count.files)개 파일 · \(count.symbols)개 심볼")
                        } else {
                            Text(languageName(language))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if snapshot.diagnosticsCount > 0 {
                DisclosureGroup("분석 진단 \(snapshot.diagnosticsCount)건") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(snapshot.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(diagnostic.file).font(.caption.monospaced())
                                    Text(diagnostic.message).font(.caption)
                                }
                            }
                            if snapshot.diagnosticsTruncated {
                                Text("진단의 일부만 표시합니다. 전체 결과는 인덱서 출력에서 확인할 수 있습니다.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 100)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var freshnessSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.isVerifying {
                    ProgressView().controlSize(.small)
                    Text("현재 소스와 비교 중…").font(.callout)
                } else {
                    Label(freshnessTitle, systemImage: freshnessIcon)
                        .font(.callout.weight(.medium)).foregroundStyle(freshnessColor)
                    if let check = model.verification {
                        Text(Date(timeIntervalSince1970: Double(check.checkedAt) / 1000), format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("최신 상태 확인") { Task { await model.verifyFreshness() } }
                    .disabled(model.isVerifying || isAnalyzing)
            }
            if let check = model.verification {
                if check.complete {
                    Text("\(check.checkedFiles)개 파일 확인 · 추가 \(check.added) · 수정 \(check.modified) · 삭제 \(check.deleted)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if check.revisionChanged == true {
                        Text("Git revision은 분석 당시와 다릅니다. 위 상태는 소스 파일 내용을 비교한 결과입니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if check.currentRevision == nil {
                        Text("현재 Git revision은 확인하지 못했습니다. 파일 내용 비교와는 별도입니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(verificationReason(check.reason)).font(.caption).foregroundStyle(.secondary)
                }
                if !check.samples.isEmpty {
                    DisclosureGroup("변경 파일 \(check.added + check.modified + check.deleted)개") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(check.samples) { sample in
                                    Text("\(changeName(sample.change)) · \(sample.path)").font(.caption.monospaced())
                                }
                                if check.samples.count < check.added + check.modified + check.deleted {
                                    Text("변경 파일 중 \(check.samples.count)개만 표시합니다.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .frame(maxHeight: 90)
                    }
                    .font(.caption)
                }
            } else if let error = model.verificationError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var freshnessTitle: String {
        guard let check = model.verification, check.complete else { return "확인하지 못함" }
        switch check.state {
        case "current": return "최신 · 확인 시점의 소스와 일치"
        case "changed": return "변경됨 · 다시 분석이 필요합니다"
        default: return "확인하지 못함"
        }
    }

    private var freshnessIcon: String {
        guard let check = model.verification, check.complete else { return "questionmark.circle" }
        return check.state == "current" ? "checkmark.circle" : "exclamationmark.circle"
    }

    private var freshnessColor: Color {
        guard let check = model.verification, check.complete else { return .secondary }
        return check.state == "current" ? .green : .orange
    }

    private func verificationReason(_ reason: String?) -> String {
        switch reason {
        case "file_limit", "inventory_limit", "byte_limit", "time_limit":
            return "확인 가능한 파일 수·용량·시간 한도에 도달해 전체 비교를 완료하지 못했습니다."
        case "checkout_mismatch": return "현재 작업 트리와 저장된 분석의 위치가 일치하지 않습니다."
        case "snapshot_changed": return "확인 중 분석 결과가 갱신되었습니다. 다시 확인해 주세요."
        case "working_tree_changed": return "확인 중 파일이 바뀌었습니다. 편집이 끝난 뒤 다시 확인해 주세요."
        case "no_index": return "이 작업 트리에 저장된 분석 결과가 없습니다."
        case "manifest_incomplete": return "저장된 파일 목록을 모두 읽지 못했습니다. 다시 분석해 주세요."
        default: return "파일이나 Git 정보를 읽지 못해 비교를 완료하지 못했습니다."
        }
    }

    private func changeName(_ change: String) -> String {
        switch change { case "added": return "추가"; case "deleted": return "삭제"; default: return "수정" }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            state("분석 결과를 불러오는 중", detail: "이 작업 트리에 저장된 코드 구조를 읽고 있습니다.", progress: true)
        } else if let error = model.errorMessage {
            state("코드 인덱스를 열 수 없습니다", detail: error, action: "다시 시도") {
                Task { await model.reload() }
            }
        } else if model.snapshot == nil {
            state(
                isAnalyzing ? "작업 트리를 분석하고 있습니다" : "이 작업 트리의 분석 결과가 없습니다",
                detail: "Python·Swift·JavaScript/TypeScript·Rust 파일을 분석해 코드 구조를 저장합니다.",
                progress: isAnalyzing,
                action: isAnalyzing ? nil : "이 작업 트리 분석",
                perform: analyze
            )
        } else {
            HSplitView {
                browser.frame(minWidth: 300, idealWidth: 360)
                detail.frame(minWidth: 420)
            }
            .disabled(isAnalyzing)
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Picker("검색 대상", selection: $model.browseMode) {
                    ForEach(CodeIndexBrowseMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.browseMode) { _ in model.scheduleSearch() }
                TextField(model.browseMode == .files ? "파일 경로 검색" : "함수·클래스 이름 검색", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.searchText) { _ in model.scheduleSearch() }
                Picker("언어", selection: $model.language) {
                    Text("모든 언어").tag("")
                    ForEach(model.snapshot?.languages ?? [], id: \.self) { language in
                        Text(languageName(language)).tag(language)
                    }
                }
                .onChange(of: model.language) { _ in model.scheduleSearch() }
            }
            .padding(12)
            Divider()
            if let error = model.listErrorMessage {
                state("목록을 읽지 못했습니다", detail: error, action: "다시 시도") {
                    Task { await model.reloadResults() }
                }
            } else if listIsEmpty, model.isLoadingList {
                state("검색 중", detail: "", progress: true)
            } else if listIsEmpty {
                state("검색 결과가 없습니다", detail: "검색어나 언어 필터를 바꿔 보세요.")
            } else {
                List(selection: listSelection) {
                    if model.browseMode == .files {
                        ForEach(model.files) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(file.path, systemImage: "doc.text")
                                    .font(.callout)
                                    .lineLimit(2)
                                Text(languageName(file.language)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .tag(file.id)
                            .help(file.path)
                        }
                    } else {
                        ForEach(model.symbols) { symbol in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(symbol.qualifiedName.isEmpty ? symbol.name : symbol.qualifiedName)
                                    .font(.callout.weight(.medium)).lineLimit(2)
                                Text("\(symbol.kind) · \(symbol.file):\(symbol.startLine)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(.vertical, 4)
                            .tag(symbol.id)
                        }
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack {
                    Text("\(model.browseMode == .files ? model.files.count : model.symbols.count)개 표시")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.isLoadingList { ProgressView().controlSize(.small) }
                    if model.nextOffset != nil {
                        Button("더 보기") { Task { await model.loadMore() } }
                            .disabled(model.isLoadingList)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection = model.selection {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(selection.title).font(.headline).textSelection(.enabled)
                            if !selection.isFile {
                                Text("\(selection.path):\(selection.line)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("소스 보기") { onOpenSource(selection.path, selection.line) }
                    }
                    Picker("관계", selection: Binding(
                        get: { model.detailMode },
                        set: { model.detailMode = $0; model.scheduleDetail() }
                    )) {
                        Text(selection.isFile ? "가져오는 파일" : "호출하는 코드").tag(CodeIndexDetailMode.outgoing)
                        Text(selection.isFile ? "이 파일을 사용" : "이 코드를 호출").tag(CodeIndexDetailMode.incoming)
                        Text("변경 영향").tag(CodeIndexDetailMode.impact)
                    }
                    .pickerStyle(.segmented)
                    if model.detailMode == .impact {
                        HStack {
                            Text("확인된 호출·의존 관계를 거슬러 추적합니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Picker("깊이", selection: Binding(
                                get: { model.impactDepth },
                                set: { model.impactDepth = $0; model.scheduleDetail() }
                            )) {
                                ForEach(1...5, id: \.self) { Text("\($0)단계").tag($0) }
                            }
                            .frame(width: 120)
                        }
                    }
                }
                .padding(16)
                Divider()
                detailContent
            }
        } else {
            state("파일이나 심볼을 선택하세요", detail: "호출·의존 관계와 변경 시 영향을 받을 수 있는 코드를 확인할 수 있습니다.")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if model.isLoadingDetail {
            state("관계를 읽는 중", detail: "", progress: true)
        } else if let error = model.detailErrorMessage {
            state("관계를 읽지 못했습니다", detail: error, action: "다시 시도") { model.scheduleDetail() }
        } else if model.detailMode == .impact, model.impacted.isEmpty {
            state("확인된 영향 관계가 없습니다", detail: "분석된 정적 관계 기준입니다. 동적 호출이나 실행 시 의존 관계는 포함되지 않습니다.")
        } else if model.detailMode != .impact, model.relations.isEmpty {
            state("기록된 관계가 없습니다", detail: "저장된 분석 결과에 이 방향의 관계가 없습니다.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.detailMode == .impact {
                        ForEach(model.impacted) { item in impactRow(item) }
                    } else {
                        ForEach(model.relations) { relation in relationRow(relation) }
                    }
                    if model.detailTruncated {
                        Text("지정한 깊이 또는 결과 수에 도달했습니다. 전체 영향 범위가 아닐 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary).padding(16)
                    }
                }
            }
        }
    }

    private func relationRow(_ relation: CodeIndexRelation) -> some View {
        let key = model.detailMode == .incoming ? relation.source : relation.target
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                if let key, model.detailSymbols[key] != nil || key.hasPrefix("file:") {
                    Button(model.displayName(for: key)) { model.navigate(to: key) }
                        .buttonStyle(.link)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(relation.name).textSelection(.enabled)
                }
                Spacer()
                if relation.resolution != "resolved" {
                    Label("미확인", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .help("정적 분석으로 대상을 확정하지 못한 참조입니다.")
                }
            }
            Button {
                onOpenSource(relation.file, relation.line)
            } label: {
                Label("\(relation.file):\(relation.line)", systemImage: "arrow.up.right.square")
                    .font(.caption.monospaced())
                    .lineLimit(2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("참조가 나타나는 소스 위치 보기")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func impactRow(_ item: CodeIndexImpact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                if model.detailSymbols[item.id] != nil || item.id.hasPrefix("file:") {
                    Button(model.displayName(for: item.id)) { model.navigate(to: item.id) }
                        .buttonStyle(.link).multilineTextAlignment(.leading)
                } else {
                    Text(model.displayName(for: item.id)).textSelection(.enabled)
                }
                Spacer()
                Text("\(item.distance)단계").font(.caption).foregroundStyle(.secondary)
            }
            if let location = model.location(for: item.id) {
                Button { onOpenSource(location.path, location.line) } label: {
                    Label("\(location.path):\(location.line)", systemImage: "arrow.up.right.square")
                        .font(.caption.monospaced()).lineLimit(2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isAnalyzing {
                ProgressView().controlSize(.small)
                Text("이 작업 트리를 분석하고 있습니다. 큰 저장소는 몇 분 걸립니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("최신 상태는 지원 소스 파일의 내용 기준이며, 코드의 동작이나 설계 판단의 유효성을 검증하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var listIsEmpty: Bool { model.browseMode == .files ? model.files.isEmpty : model.symbols.isEmpty }

    private var listSelection: Binding<String?> {
        Binding(get: { model.selection?.id }, set: { id in
            if let file = model.files.first(where: { $0.id == id }), model.browseMode == .files {
                model.selectFile(file)
            } else if let symbol = model.symbols.first(where: { $0.id == id }), model.browseMode == .symbols {
                model.selectSymbol(symbol)
            }
        })
    }

    private func messageBar(_ message: String, isError: Bool = false) -> some View {
        HStack {
            Label(message, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.caption)
                .foregroundStyle(isError ? Color.red : Color.secondary)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func state(
        _ title: String, detail: String, progress: Bool = false,
        action: String? = nil, perform: @escaping () -> Void = {}
    ) -> some View {
        VStack(spacing: 12) {
            if progress { ProgressView().controlSize(.small) }
            Text(title).font(.headline)
            if !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            if let action { Button(action, action: perform) }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func analyze() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        analysisError = nil
        analysisTask = Task {
            do {
                try await onAnalyze()
                guard !Task.isCancelled else { return }
                await model.reload()
            } catch {
                guard !Task.isCancelled else { return }
                analysisError = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func languageName(_ language: String) -> String {
        switch language {
        case "python": return "Python"
        case "swift": return "Swift"
        case "javascript": return "JavaScript"
        case "typescript": return "TypeScript"
        case "rust": return "Rust"
        default: return language
        }
    }
}
