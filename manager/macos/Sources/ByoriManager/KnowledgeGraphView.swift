import ByoriManagerCore
import SwiftUI

struct KnowledgeGraphView: View {
    @EnvironmentObject private var graph: KnowledgeGraphViewModel
    @EnvironmentObject private var manager: ManagerViewModel
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var fitRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "지식 그래프",
                subtitle: "ByoriDB에 저장된 기억과 관계를 읽기 전용으로 탐색합니다."
            )
            controls
            content
        }
        .padding(28)
        .task { await graph.load() }
        .onChange(of: graph.layoutMode) { _ in rebuildAndFit() }
        .onChange(of: graph.selectedKind) { _ in rebuildAndFit() }
        .onChange(of: graph.searchText) { _ in rebuildAndFit() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("이름 또는 종류 검색", text: $graph.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 230)

            Picker("종류", selection: $graph.selectedKind) {
                Text("모든 종류").tag("")
                ForEach(graph.kinds, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 150)

            Picker("배치", selection: $graph.layoutMode) {
                ForEach(KnowledgeGraphLayoutMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)

            Spacer()

            Button {
                zoom = max(0.3, zoom - 0.15)
            } label: {
                Label("축소", systemImage: "minus.magnifyingglass")
            }
            .labelStyle(.iconOnly)

            Button {
                zoom = min(3, zoom + 0.15)
            } label: {
                Label("확대", systemImage: "plus.magnifyingglass")
            }
            .labelStyle(.iconOnly)

            Button {
                fitRequest += 1
            } label: {
                Label("화면에 맞춤", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .labelStyle(.iconOnly)

            Button {
                Task { await graph.load(force: true) }
            } label: {
                Label("그래프 새로고침", systemImage: "arrow.clockwise")
            }
            .disabled(graph.isLoading)
        }
    }

    @ViewBuilder
    private var content: some View {
        if graph.snapshot == nil, graph.isLoading {
            GraphStateView(
                icon: "point.3.connected.trianglepath.dotted",
                title: "지식 그래프를 불러오는 중",
                detail: "로컬 ByoriDB에서 기억과 관계를 읽고 있습니다.",
                showsProgress: true
            )
        } else if graph.snapshot == nil, let error = graph.errorMessage {
            GraphStateView(
                icon: "externaldrive.badge.exclamationmark",
                title: "그래프를 열 수 없습니다",
                detail: error,
                primaryTitle: "다시 시도",
                primaryAction: { Task { await graph.load(force: true) } },
                secondaryTitle: "유지관리 열기",
                secondaryAction: { manager.selectedSection = .maintenance }
            )
        } else if graph.snapshot?.nodes.isEmpty != false {
            GraphStateView(
                icon: "circle.hexagongrid",
                title: "아직 저장된 기억이 없습니다",
                detail: "Claude 또는 Codex에서 Byori Memory Skill로 기억을 저장하면 여기에 표시됩니다.",
                primaryTitle: "에이전트 연결 열기",
                primaryAction: { manager.selectedSection = .integrations }
            )
        } else {
            HSplitView {
                GraphViewport(
                    graph: graph.filteredSnapshot,
                    positions: graph.positions,
                    selectedNodeID: graph.selectedNodeID,
                    rootNodeID: graph.rootNodeID,
                    isLoading: graph.isLoading,
                    fitRequest: fitRequest,
                    zoom: $zoom,
                    pan: $pan,
                    select: graph.select
                )
                .frame(minWidth: 480, minHeight: 430)

                NodeInspector(fitRequest: $fitRequest)
                    .environmentObject(graph)
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .top) {
                if graph.snapshot?.nodesTruncated == true || graph.snapshot?.edgesTruncated == true {
                    Label(
                        "큰 그래프의 일부만 표시합니다(노드 최대 200개). 검색으로 범위를 좁혀 보세요.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                }
            }
        }
    }

    private func rebuildAndFit() {
        graph.rebuildLayout()
        fitRequest += 1
    }
}

private struct GraphViewport: View {
    let graph: KnowledgeGraphSnapshot?
    let positions: [Int64: GraphPoint]
    let selectedNodeID: Int64?
    let rootNodeID: Int64?
    let isLoading: Bool
    let fitRequest: Int
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    let select: (Int64) -> Void

    @State private var panStart: CGSize?
    @State private var zoomStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .controlBackgroundColor)

                Canvas { context, size in
                    drawEdges(context: &context, size: size)
                }

                if let graph {
                    ForEach(graph.nodes) { node in
                        if let point = positions[node.id] {
                            GraphNodeCard(
                                node: node,
                                isSelected: selectedNodeID == node.id,
                                isRoot: rootNodeID == node.id,
                                compact: zoom < 0.58,
                                action: { select(node.id) }
                            )
                            .scaleEffect(zoom)
                            .position(screenPoint(point, in: geometry.size))
                        }
                    }
                }

                if graph?.nodes.isEmpty == true {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                        Text("필터와 일치하는 기억이 없습니다.")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack {
                    Spacer()
                    HStack {
                        if let graph {
                            Text("노드 \(graph.nodes.count) · 관계 \(graph.edges.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        Spacer()
                        Text("\(Int(zoom * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(12)
                }

                if isLoading {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .simultaneousGesture(panGesture)
            .simultaneousGesture(zoomGesture)
            .onAppear { fit(in: geometry.size) }
            .onChange(of: fitRequest) { _ in fit(in: geometry.size) }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if panStart == nil { panStart = pan }
                let start = panStart ?? pan
                pan = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
            }
            .onEnded { _ in panStart = nil }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = zoom }
                zoom = min(3, max(0.3, (zoomStart ?? zoom) * value))
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func screenPoint(_ point: GraphPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2 + pan.width + CGFloat(point.x) * zoom,
            y: size.height / 2 + pan.height + CGFloat(point.y) * zoom
        )
    }

    private func fit(in size: CGSize) {
        guard !positions.isEmpty else {
            zoom = 1
            pan = .zero
            return
        }
        let values = Array(positions.values)
        let minX = values.map(\.x).min() ?? 0
        let maxX = values.map(\.x).max() ?? 0
        let minY = values.map(\.y).min() ?? 0
        let maxY = values.map(\.y).max() ?? 0
        let graphWidth = max(190, maxX - minX + 190)
        let graphHeight = max(90, maxY - minY + 100)
        let horizontal = max(0.3, (size.width - 60) / CGFloat(graphWidth))
        let vertical = max(0.3, (size.height - 70) / CGFloat(graphHeight))
        zoom = min(1.35, max(0.3, min(horizontal, vertical)))
        pan = .zero
    }

    private func drawEdges(context: inout GraphicsContext, size: CGSize) {
        guard let graph else { return }
        for edge in graph.edges {
            guard let source = positions[edge.source], let target = positions[edge.target] else {
                continue
            }
            let startCenter = screenPoint(source, in: size)
            let endCenter = screenPoint(target, in: size)
            let dx = endCenter.x - startCenter.x
            let dy = endCenter.y - startCenter.y
            let distance = max(1, sqrt(dx * dx + dy * dy))
            let ux = dx / distance
            let uy = dy / distance
            let inset = 38 * zoom
            let start = CGPoint(x: startCenter.x + ux * inset, y: startCenter.y + uy * inset)
            let end = CGPoint(x: endCenter.x - ux * inset, y: endCenter.y - uy * inset)
            let selected = selectedNodeID == edge.source || selectedNodeID == edge.target
            let color = selected ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.38)

            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: selected ? 2 : 1.2,
                    dash: edge.kind == "relates_to" ? [6, 5] : []
                )
            )

            let arrowSize = max(4, 7 * zoom)
            let perpendicular = CGPoint(x: -uy, y: ux)
            var arrow = Path()
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(
                x: end.x - ux * arrowSize + perpendicular.x * arrowSize * 0.55,
                y: end.y - uy * arrowSize + perpendicular.y * arrowSize * 0.55
            ))
            arrow.addLine(to: CGPoint(
                x: end.x - ux * arrowSize - perpendicular.x * arrowSize * 0.55,
                y: end.y - uy * arrowSize - perpendicular.y * arrowSize * 0.55
            ))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(color))
        }
    }
}

private struct GraphNodeCard: View {
    let node: KnowledgeNode
    let isSelected: Bool
    let isRoot: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(kindColor(node.kind))
                    .frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(compact ? 1 : 2)
                    if !compact {
                        Text(node.kind)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                if isRoot {
                    Image(systemName: "scope")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 174, height: 60, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .shadow(color: .black.opacity(isSelected ? 0.16 : 0.07), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(node.name), \(node.kind)")
        .accessibilityHint(isRoot ? "현재 그래프 중심 노드" : "상세 내용을 보려면 선택")
        .help(node.name)
    }
}

private struct NodeInspector: View {
    @EnvironmentObject private var graph: KnowledgeGraphViewModel
    @Binding var fitRequest: Int

    var body: some View {
        Group {
            if let node = graph.selectedNode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            Circle()
                                .fill(kindColor(node.kind))
                                .frame(width: 12, height: 12)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(node.name).font(.title3.bold()).textSelection(.enabled)
                                Text(node.kind).font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        if node.timestamp > 0 {
                            Label(
                                node.updatedAt.formatted(date: .abbreviated, time: .shortened),
                                systemImage: "clock"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Button("이 노드를 중심으로") {
                            graph.centerOnSelectedNode()
                            fitRequest += 1
                        }
                        .buttonStyle(.borderedProminent)

                        Divider()
                        Text("본문").font(.headline)
                        if graph.isLoadingBody {
                            ProgressView("본문 불러오는 중…").controlSize(.small)
                        } else if let error = graph.bodyErrorMessage {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else {
                            Text(graph.selectedBody?.isEmpty == false ? graph.selectedBody! : "본문이 없습니다.")
                                .foregroundStyle(graph.selectedBody?.isEmpty == false ? .primary : .secondary)
                                .textSelection(.enabled)
                        }

                        Divider()
                        Text("관계 \(graph.selectedRelations.count)").font(.headline)
                        if graph.selectedRelations.isEmpty {
                            Text("연결된 기억이 없습니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(graph.selectedRelations.prefix(30)) { edge in
                                let outgoing = edge.source == node.id
                                let otherID = outgoing ? edge.target : edge.source
                                Button {
                                    graph.select(otherID)
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: outgoing ? "arrow.right" : "arrow.left")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(graph.snapshot?.node(id: otherID)?.name ?? String(otherID))
                                                .lineLimit(2)
                                            Text(edge.kind)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(18)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.title2)
                    Text("노드를 선택하면\n상세 내용이 표시됩니다.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct GraphStateView: View {
    let icon: String
    let title: String
    let detail: String
    var showsProgress = false
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 13) {
            if showsProgress {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }
            Text(title).font(.title3.bold())
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack {
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle, action: primaryAction).buttonStyle(.borderedProminent)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }
}

private func kindColor(_ kind: String) -> Color {
    let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green]
    let seed = kind.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
    return palette[seed % palette.count]
}
