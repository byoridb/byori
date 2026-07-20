import ByoriManagerCore
import Foundation

@MainActor
final class KnowledgeGraphViewModel: ObservableObject {
    @Published private(set) var snapshot: KnowledgeGraphSnapshot?
    @Published private(set) var positions: [Int64: GraphPoint] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedBody: String?
    @Published private(set) var bodyErrorMessage: String?
    @Published private(set) var isLoadingBody = false
    @Published var selectedNodeID: Int64?
    @Published var rootNodeID: Int64?
    @Published var layoutMode: KnowledgeGraphLayoutMode = .mindMap
    @Published var searchText = ""
    @Published var selectedKind = ""

    private let service: ManagerService
    private var bodies: [Int64: String] = [:]
    private var bodyTask: Task<Void, Never>?

    init(service: ManagerService) {
        self.service = service
    }

    var kinds: [String] {
        Array(Set(snapshot?.nodes.map(\.kind) ?? [])).sorted()
    }

    var filteredSnapshot: KnowledgeGraphSnapshot? {
        guard let snapshot else { return nil }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodes = snapshot.nodes.filter { node in
            let matchesKind = selectedKind.isEmpty || node.kind == selectedKind
            let matchesQuery = query.isEmpty
                || node.name.localizedCaseInsensitiveContains(query)
                || node.kind.localizedCaseInsensitiveContains(query)
            return matchesKind && matchesQuery
        }
        let ids = Set(nodes.map(\.id))
        return KnowledgeGraphSnapshot(
            nodes: nodes,
            edges: snapshot.edges.filter { ids.contains($0.source) && ids.contains($0.target) },
            loadedAt: snapshot.loadedAt,
            nodesTruncated: snapshot.nodesTruncated,
            edgesTruncated: snapshot.edgesTruncated
        )
    }

    var selectedNode: KnowledgeNode? {
        snapshot?.node(id: selectedNodeID)
    }

    var selectedRelations: [KnowledgeEdge] {
        guard let selectedNodeID, let snapshot else { return [] }
        return snapshot.edges.filter {
            $0.source == selectedNodeID || $0.target == selectedNodeID
        }
    }

    func load(force: Bool = false) async {
        if isLoading || (!force && snapshot != nil) { return }
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await service.loadKnowledgeGraph(limit: 200)
            snapshot = loaded
            bodies.removeAll(keepingCapacity: true)
            selectedBody = nil
            let suggested = KnowledgeGraphLayout.suggestedRoot(
                for: loaded,
                preferred: rootNodeID
            )
            rootNodeID = suggested
            if loaded.node(id: selectedNodeID) == nil {
                selectedNodeID = nil
            }
            rebuildLayout()
            if let selectedNodeID {
                loadBody(for: selectedNodeID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func rebuildLayout() {
        guard let graph = filteredSnapshot else {
            positions = [:]
            return
        }
        if graph.node(id: rootNodeID) == nil {
            rootNodeID = KnowledgeGraphLayout.suggestedRoot(for: graph)
        }
        positions = KnowledgeGraphLayout.positions(
            for: graph,
            mode: layoutMode,
            rootID: rootNodeID
        )
    }

    func select(_ nodeID: Int64) {
        selectedNodeID = nodeID
        loadBody(for: nodeID)
    }

    func centerOnSelectedNode() {
        guard let selectedNodeID else { return }
        rootNodeID = selectedNodeID
        rebuildLayout()
    }

    private func loadBody(for nodeID: Int64) {
        bodyTask?.cancel()
        bodyErrorMessage = nil
        if let cached = bodies[nodeID] {
            selectedBody = cached
            isLoadingBody = false
            return
        }
        selectedBody = nil
        isLoadingBody = true
        bodyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let body = try await service.loadKnowledgeBody(nodeID: nodeID)
                guard !Task.isCancelled else { return }
                bodies[nodeID] = body
                if selectedNodeID == nodeID { selectedBody = body }
            } catch {
                guard !Task.isCancelled, selectedNodeID == nodeID else { return }
                bodyErrorMessage = error.localizedDescription
            }
            if selectedNodeID == nodeID { isLoadingBody = false }
        }
    }
}
