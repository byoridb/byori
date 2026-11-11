import AppKit
import ByoriManagerCore
import SwiftUI

struct WorkspaceTaskWorkView: View {
    private enum Page: String, CaseIterable { case workflow = "절차", verification = "검증" }
    @StateObject private var model: WorkspaceTaskWorkViewModel
    @State private var page: Page = .workflow
    @State private var confirmsPreset = false
    @State private var editsCommands = false
    @State private var copied = false
    private let onClose: () -> Void

    init(scope: WorkspaceTaskWorkScope, provider: any WorkspaceTaskWorkProviding, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: WorkspaceTaskWorkViewModel(scope: scope, provider: provider))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("작업 절차·검증").font(.title3.weight(.semibold))
                    Text(model.scope.title).font(.callout)
                    Text(model.scope.root.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("닫기", action: onClose).keyboardShortcut(.cancelAction).disabled(model.isBusy)
            }.padding(20)
            Picker("보기", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 16)
            Divider()
            if model.isLoading {
                ProgressView("저장된 절차와 현재 코드 상태를 확인하는 중")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if page == .workflow { workflow } else { verification }
                        if page == .workflow, let error = model.workflowError {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if let error = model.errorMessage {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 620, idealHeight: 780)
        .interactiveDismissDisabled(model.isBusy)
        .task { await model.load() }
        .onDisappear { model.close() }
        .alert("현재 절차를 바꿀까요?", isPresented: $confirmsPreset) {
            Button("취소", role: .cancel) {}
            Button("새 절차 적용") { model.applyPreset() }
        } message: {
            Text("현재 목표를 유지하고 단계·완료 조건·메모를 선택한 절차의 초안으로 바꿉니다. 저장하기 전에는 기존 저장 내용이 유지됩니다.")
        }
    }

    private var workflow: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("작업 절차", selection: $model.selectedPreset) {
                    ForEach(TaskWorkflowPreset.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 340)
                Button("초안 적용") {
                    if model.hasWorkflowToReplace { confirmsPreset = true } else { model.applyPreset() }
                }
                Spacer()
            }
            Text(model.selectedPreset.summary).font(.callout).foregroundStyle(.secondary)
            field("목표", text: $model.plan.goal, height: 55)
            Text("작업 단계").font(.headline)
            Text("직접 확인한 단계에 표시하세요. 체크 표시는 명령 실행이나 테스트 통과를 의미하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($model.plan.steps) { $step in
                Toggle(isOn: $step.completed) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).font(.body.weight(.medium))
                        Text(step.instructions).font(.callout).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.checkbox)
            }
            field("완료 조건", text: $model.plan.acceptanceCriteria, height: 65)
            field("진행 메모", text: $model.plan.notes, height: 65)
            Text("인계문은 현재 작성 내용과 마지막으로 확인한 검증 상태를 포함합니다. 복사한 문장은 자동 실행되지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.isBusy || !model.hasLoadedWorkflow)
    }

    private var verification: some View {
        VStack(alignment: .leading, spacing: 16) {
            assessmentSummary
            if let error = model.verificationError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let snapshot = model.snapshot {
                if snapshot.profile.commands.isEmpty {
                    Text("아직 검증 명령이 없습니다. 아래에서 프로젝트에 맞는 명령을 추가하고 저장하세요.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.profile.commands) { command in
                        commandRow(command, assessment: snapshot.assessment(for: command))
                    }
                }
            }
            if model.isProfileDirty {
                Label("명령 편집 내용이 저장되지 않았습니다. 저장 후 실행할 수 있습니다.", systemImage: "pencil")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("프로젝트 검증 명령 편집", isExpanded: $editsCommands) {
                commandEditor.padding(.top, 12)
            }
            Divider()
            history
            Text("최근 실행 30건의 제한된 출력을 이 Mac의 작업 기록에 보관합니다. 출력은 ByoriDB 기억에 저장하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var assessmentSummary: some View {
        if model.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.isCancelling ? "프로세스를 중지하고 기록을 정리하는 중" : "검증 명령 실행 중")
            }
        } else if model.isRefreshing {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("현재 코드와 실행 기록을 대조하는 중") }
        } else if model.isProfileDirty {
            VStack(alignment: .leading, spacing: 5) {
                Label("명령 변경 미저장", systemImage: "pencil").font(.headline)
                Text("기록은 기존 저장 설정의 실행 결과입니다. 변경한 명령을 저장하고 다시 검증하세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if let assessment = model.snapshot?.requiredAssessment {
            VStack(alignment: .leading, spacing: 5) {
                Label("필수 검증 · \(assessment.state.title)", systemImage: icon(assessment.state))
                    .font(.headline).foregroundStyle(color(assessment.state))
                Text(assessment.detail).font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Text("현재 검증 상태를 확인할 수 없습니다.").foregroundStyle(.secondary)
        }
        Text("표시는 마지막 확인 시점의 소스 상태를 기준으로 합니다. 코드를 수정한 뒤에는 상태 새로 고침으로 다시 확인하세요.")
            .font(.caption).foregroundStyle(.secondary)
        if let checkedAt = model.snapshot?.current?.checkedAt {
            Text("코드 상태 확인: \(checkedAt.formatted())").font(.caption).foregroundStyle(.secondary)
        }
        if let reason = model.snapshot?.current?.reason {
            Text("현재 코드 확인 제한: \(reason)").font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func commandRow(_ command: VerificationCommand, assessment: VerificationAssessment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(command.name).font(.body.weight(.medium))
                    if command.required { Text("필수").font(.caption).foregroundStyle(.secondary) }
                }
                Text(command.displayCommand)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if model.runningCommandID == command.id {
                    Text(model.isCancelling ? "취소 처리 중" : "실행 중").font(.caption)
                } else if model.isRefreshing {
                    Text("상태 확인 중").font(.caption).foregroundStyle(.secondary)
                } else if model.isProfileDirty {
                    Text("기존 저장 설정: \(assessment.state.title)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(assessment.state.title, systemImage: icon(assessment.state))
                        .font(.caption).foregroundStyle(color(assessment.state))
                    Text(assessment.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("실행") { model.run(commandID: command.id) }.disabled(!model.canRun)
                .accessibilityLabel("\(command.name) 실행")
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }

    private var commandEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("이 프로젝트의 모든 작업에서 공유하는 명령입니다. 실행 위치는 위에 표시한 작업 트리입니다.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($model.commandDrafts) { $draft in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("명령 이름", text: $draft.name).textFieldStyle(.roundedBorder)
                        Button("삭제", role: .destructive) { model.removeCommand(id: draft.id) }
                    }
                    TextField("실행 파일 (예: cargo 또는 절대 경로)", text: $draft.executable)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    field("인수 — 한 줄에 하나, 빈 줄은 제외", text: $draft.argumentsText, height: 52)
                    HStack {
                        Text("제한 시간")
                        TextField("초", text: $draft.timeoutText).textFieldStyle(.roundedBorder).frame(width: 75)
                        Text("초 (최대 1,800)").foregroundStyle(.secondary)
                        Spacer()
                        Toggle("필수 검증", isOn: $draft.required).toggleStyle(.checkbox)
                    }.font(.callout)
                }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Menu("명령 추가") {
                    ForEach(WorkspaceVerificationStarter.allCases) { starter in
                        Button(starter.rawValue) { model.addCommand(starter) }
                    }
                }.disabled(model.commandDrafts.count >= 12)
                Text("\(model.commandDrafts.count)/12").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("명령 저장") { Task { await model.saveCommands() } }.disabled(!model.isProfileDirty)
            }
            Text("실행 파일과 인수를 분리해 저장합니다. 인수의 따옴표·공백·파이프 기호는 셸 문법으로 해석하지 않고 그대로 전달합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.isBusy || model.snapshot == nil)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("실행 기록").font(.headline)
            if let snapshot = model.snapshot, !snapshot.receipts.isEmpty {
                Picker("기록", selection: Binding(
                    get: { model.selectedReceipt?.id ?? "" }, set: { model.selectedReceiptID = $0 }
                )) {
                    ForEach(snapshot.receipts) { receipt in
                        Text("\(receipt.startedAt.formatted(date: .abbreviated, time: .standard)) · \(receipt.command.name) · \(outcomeTitle(receipt.outcome))")
                            .tag(receipt.id)
                    }
                }.labelsHidden()
                if let receipt = model.selectedReceipt { receiptDetail(receipt) }
            } else {
                Text("저장된 실행 기록이 없습니다.").foregroundStyle(.secondary)
            }
        }
    }

    private func receiptDetail(_ receipt: VerificationReceipt) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("실행 당시 결과: \(outcomeTitle(receipt.outcome)) · 종료 코드: \(receipt.exitCode.map(String.init) ?? "없음")")
                .font(.callout)
            Text("시작 \(receipt.startedAt.formatted()) · 종료 \(receipt.finishedAt?.formatted() ?? "미기록")")
                .font(.caption).foregroundStyle(.secondary)
            Text("실행 위치: \(receipt.scope.root.path)")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("제한 시간: \(receipt.command.timeout.formatted())초")
                .font(.caption).foregroundStyle(.secondary)
            Text("실행 파일: \(receipt.resolvedExecutable)")
                .font(.caption.monospaced()).textSelection(.enabled)
            if !receipt.command.arguments.isEmpty {
                Text("인수 (줄마다 하나)\n" + receipt.command.arguments.joined(separator: "\n"))
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            Text("실행 전 revision: \(receipt.before?.revision ?? "미확인")\n실행 후 revision: \(receipt.after?.revision ?? "미확인")")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let before = receipt.before {
                Text("실행 전 관측: \(before.files)개 파일 · \(before.bytes)바이트 · \(before.complete ? "완료" : "불완전")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let after = receipt.after {
                Text("실행 후 관측: \(after.files)개 파일 · \(after.bytes)바이트 · \(after.complete ? "완료" : "불완전")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let coverage = receipt.after?.coverage ?? receipt.before?.coverage {
                Text("관측 범위: \(coverage)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let reason = receipt.after?.reason ?? receipt.before?.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(receipt.output.isEmpty ? "출력 없음" : receipt.output)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(10)
            }.frame(height: 190).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            if receipt.outputTruncated {
                Text("출력 보관 한도(64 KiB)를 넘어 마지막 부분만 표시합니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if page == .workflow {
                if !model.hasLoadedWorkflow {
                    Button("절차 다시 불러오기") { Task { await model.retryWorkflowLoad() } }.disabled(model.isBusy)
                }
                Button(copied ? "인계문 복사됨" : "인계문 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.handoffText, forType: .string)
                    copied = true
                }.disabled(model.isBusy || !model.hasLoadedWorkflow)
                Spacer()
                Button("절차 저장") { Task { await model.saveWorkflow() } }
                    .disabled(model.isBusy || !model.hasLoadedWorkflow || !model.isWorkflowDirty || model.plan.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("상태 새로 고침") { Task { await model.refreshVerification() } }.disabled(model.isBusy)
                Spacer()
                if model.isRunning {
                    Button(model.isCancelling ? "취소 처리 중…" : "실행 취소", role: .cancel) { model.cancelRun() }
                        .disabled(model.isCancelling)
                }
            }
            if model.isSaving || model.isRefreshing { ProgressView().controlSize(.small) }
        }
    }

    private func field(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            TextEditor(text: text).font(.body).frame(minHeight: height)
                .border(Color.secondary.opacity(0.25)).accessibilityLabel(title)
        }
    }

    private func color(_ state: VerificationState) -> Color {
        switch state {
        case .passed: return .green
        case .failed, .timedOut: return .red
        case .stale, .unverified, .interrupted: return .orange
        default: return .secondary
        }
    }

    private func icon(_ state: VerificationState) -> String {
        switch state {
        case .passed: return "checkmark.circle"
        case .failed, .timedOut: return "xmark.circle"
        case .stale, .unverified, .interrupted: return "exclamationmark.triangle"
        case .running: return "clock"
        case .cancelled: return "stop.circle"
        case .notConfigured, .notRun: return "circle.dashed"
        }
    }

    private func outcomeTitle(_ outcome: VerificationOutcome) -> String {
        switch outcome {
        case .running: return "실행 중"
        case .passed: return "통과"
        case .failed: return "실패"
        case .timedOut: return "시간 초과"
        case .cancelled: return "취소됨"
        case .interrupted: return "중단됨"
        }
    }
}
