import SwiftUI

enum WorkspaceSettingsSection: String, CaseIterable, Identifiable {
    case general = "설정 개요"
    case agents = "에이전트 · Skill"
    case byoriDB = "ByoriDB"
    case diagnostics = "진단"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .agents: return "terminal"
        case .byoriDB: return "cylinder.split.1x2"
        case .diagnostics: return "stethoscope"
        }
    }

    var accessibilityDetail: String {
        switch self {
        case .general: return "로컬 워크스페이스와 서비스 상태"
        case .agents: return "코딩 CLI, MCP, Memory Skill 연결"
        case .byoriDB: return "지식 데이터베이스 설치와 유지관리"
        case .diagnostics: return "설치 작업 기록, 로그와 백업"
        }
    }
}

/// Native settings container for Byori's existing administration views.
///
/// Those views are currently file-private in `ContentView.swift`, so app
/// composition should inject them from that file until their visibility is
/// deliberately changed:
///
///     SettingsRootView { section in
///         switch section {
///         case .general: AnyView(OverviewView())
///         case .agents: AnyView(IntegrationsView())
///         case .byoriDB: AnyView(MaintenanceView())
///         case .diagnostics: AnyView(ActivityView())
///         }
///     }
struct SettingsRootView: View {
    typealias Destination = (WorkspaceSettingsSection) -> AnyView

    @State private var localSelection: WorkspaceSettingsSection
    private let externalSelection: Binding<WorkspaceSettingsSection>?
    private let destination: Destination

    init(
        initialSection: WorkspaceSettingsSection = .general,
        destination: @escaping Destination
    ) {
        _localSelection = State(initialValue: initialSection)
        externalSelection = nil
        self.destination = destination
    }

    init(
        selection: Binding<WorkspaceSettingsSection>,
        destination: @escaping Destination
    ) {
        _localSelection = State(initialValue: selection.wrappedValue)
        externalSelection = selection
        self.destination = destination
    }

    /// Keeps the Settings scene buildable before existing private screens are
    /// wired. The placeholder is explicit and does not imply runtime support.
    init(initialSection: WorkspaceSettingsSection = .general) {
        _localSelection = State(initialValue: initialSection)
        externalSelection = nil
        destination = { section in
            AnyView(SettingsIntegrationPlaceholder(section: section))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(WorkspaceSettingsSection.allCases, selection: optionalSelection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
                    .accessibilityLabel("\(section.rawValue) 설정")
                    .accessibilityHint(section.accessibilityDetail)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
        } detail: {
            destination(selection.wrappedValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var selection: Binding<WorkspaceSettingsSection> {
        externalSelection ?? $localSelection
    }

    private var optionalSelection: Binding<WorkspaceSettingsSection?> {
        Binding(
            get: { selection.wrappedValue },
            set: { newValue in
                if let newValue {
                    selection.wrappedValue = newValue
                }
            }
        )
    }
}

private struct SettingsIntegrationPlaceholder: View {
    let section: WorkspaceSettingsSection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(section.rawValue) Settings")
                .font(.title2.weight(.semibold))
            Text("Connect the existing Byori settings view for this destination when the app Settings scene is composed.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
