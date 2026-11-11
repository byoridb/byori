import ByoriManagerCore
import SwiftUI

/// Recovery stays next to the service controls, with the reason, proposed
/// action and verified outcome visible before the user tries again.
struct RuntimeRecoveryView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        GroupBox("진단·복구") {
            VStack(alignment: .leading, spacing: 10) {
                if let report = model.recoveryReport {
                    Label(report.diagnosis.title, systemImage: report.diagnosis == .healthy
                          ? "checkmark.circle" : "wrench.and.screwdriver")
                        .font(.headline)
                    Text(report.diagnosis.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !report.persistenceAvailable {
                        Text(RuntimeRecoveryError.persistenceUnavailable.localizedDescription)
                            .foregroundStyle(.red)
                    } else if report.userStopped {
                        Text("직접 중지한 기록이 있어 자동 복구를 건너뜁니다. 서비스 시작 또는 복구를 직접 실행하면 다시 활성화됩니다.")
                            .foregroundStyle(.secondary)
                    }
                    if let attempt = report.lastAttempt {
                        Divider()
                        Text("최근 조치: \(attempt.action.title) · \(attempt.automatic ? "자동" : "직접 실행")")
                        HStack {
                            Text(attempt.outcome.title)
                            Spacer()
                            Text(attempt.startedAt, style: .time)
                                .foregroundStyle(.secondary)
                        }
                        if attempt.outcome == .failed {
                            Text(attempt.diagnosis.title).foregroundStyle(.secondary)
                        }
                    }
                    Text("최근 10분 \(report.attemptsUsed)/\(report.attemptLimit)회 · 시도 간 최소 1분 대기")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let next = report.nextAttemptAt {
                        Text("다음 시도: \(next.formatted(date: .omitted, time: .standard)) 이후 상태를 다시 확인해 주세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(report.diagnosis.action?.title ?? "복구") {
                            model.request(.recoverByori(automatic: false))
                        }
                        .disabled(!report.canRecover || model.isBusy || model.isCheckingRecovery)
                        refreshButton
                        Spacer()
                        Text(report.checkedAt, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("마지막 진단 시각")
                    }
                } else {
                    Text("서비스를 진단하면 원인과 가능한 조치를 확인할 수 있습니다.")
                        .foregroundStyle(.secondary)
                    refreshButton
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var refreshButton: some View {
        Button(model.isCheckingRecovery ? "확인 중…" : "상태 다시 확인") {
            Task { await model.refreshRecovery() }
        }
        .disabled(model.isBusy || model.isCheckingRecovery)
    }
}
