import Foundation

public struct KnowledgeNode: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let kind: String
    public let timestamp: Int64

    public init(id: Int64, name: String, kind: String, timestamp: Int64) {
        self.id = id
        self.name = name
        self.kind = kind
        self.timestamp = timestamp
    }

    public var updatedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
    }
}

public struct KnowledgeEdge: Identifiable, Hashable, Sendable {
    public let source: Int64
    public let target: Int64
    public let kind: String

    public var id: String { "\(source):\(target):\(kind)" }

    public init(source: Int64, target: Int64, kind: String) {
        self.source = source
        self.target = target
        self.kind = kind
    }
}

public struct KnowledgeGraphSnapshot: Equatable, Sendable {
    public let nodes: [KnowledgeNode]
    public let edges: [KnowledgeEdge]
    public let loadedAt: Date
    public let nodesTruncated: Bool
    public let edgesTruncated: Bool

    public init(
        nodes: [KnowledgeNode],
        edges: [KnowledgeEdge],
        loadedAt: Date = Date(),
        nodesTruncated: Bool = false,
        edgesTruncated: Bool = false
    ) {
        self.nodes = nodes
        self.edges = edges
        self.loadedAt = loadedAt
        self.nodesTruncated = nodesTruncated
        self.edgesTruncated = edgesTruncated
    }

    public func node(id: Int64?) -> KnowledgeNode? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    public func degree(of id: Int64) -> Int {
        edges.reduce(into: 0) { count, edge in
            if edge.source == id || edge.target == id { count += 1 }
        }
    }
}

public enum KnowledgeGraphLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case mindMap
    case network

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mindMap: return "마인드맵"
        case .network: return "관계 그래프"
        }
    }
}

public struct GraphPoint: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum KnowledgeGraphLayout {
    public static func positions(
        for graph: KnowledgeGraphSnapshot,
        mode: KnowledgeGraphLayoutMode,
        rootID: Int64? = nil
    ) -> [Int64: GraphPoint] {
        guard !graph.nodes.isEmpty else { return [:] }
        let nodeIDs = Set(graph.nodes.map(\.id))
        var adjacency = Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, Set<Int64>()) })
        for edge in graph.edges where nodeIDs.contains(edge.source) && nodeIDs.contains(edge.target) {
            adjacency[edge.source, default: []].insert(edge.target)
            adjacency[edge.target, default: []].insert(edge.source)
        }
        let components = connectedComponents(nodeIDs: nodeIDs, adjacency: adjacency)
        let ordered = orderedComponents(
            components,
            graph: graph,
            adjacency: adjacency,
            preferredRoot: rootID
        )
        let raw: [Int64: GraphPoint]
        switch mode {
        case .mindMap:
            raw = mindMapPositions(
                components: ordered,
                graph: graph,
                adjacency: adjacency,
                preferredRoot: rootID
            )
        case .network:
            raw = networkPositions(
                components: ordered,
                graph: graph,
                adjacency: adjacency,
                preferredRoot: rootID
            )
        }
        return centered(raw)
    }

    public static func suggestedRoot(
        for graph: KnowledgeGraphSnapshot,
        preferred: Int64? = nil
    ) -> Int64? {
        if let preferred, graph.nodes.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return graph.nodes.max { lhs, rhs in
            let leftDegree = graph.degree(of: lhs.id)
            let rightDegree = graph.degree(of: rhs.id)
            if leftDegree == rightDegree { return lhs.timestamp < rhs.timestamp }
            return leftDegree < rightDegree
        }?.id
    }

    private static func connectedComponents(
        nodeIDs: Set<Int64>,
        adjacency: [Int64: Set<Int64>]
    ) -> [Set<Int64>] {
        var remaining = nodeIDs
        var result: [Set<Int64>] = []
        while let seed = remaining.min() {
            var component = Set<Int64>()
            var queue = [seed]
            remaining.remove(seed)
            while !queue.isEmpty {
                let current = queue.removeFirst()
                component.insert(current)
                for neighbor in (adjacency[current] ?? []).sorted() where remaining.contains(neighbor) {
                    remaining.remove(neighbor)
                    queue.append(neighbor)
                }
            }
            result.append(component)
        }
        return result
    }

    private static func orderedComponents(
        _ components: [Set<Int64>],
        graph: KnowledgeGraphSnapshot,
        adjacency: [Int64: Set<Int64>],
        preferredRoot: Int64?
    ) -> [Set<Int64>] {
        components.sorted { lhs, rhs in
            if let preferredRoot {
                if lhs.contains(preferredRoot) != rhs.contains(preferredRoot) {
                    return lhs.contains(preferredRoot)
                }
            }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            let left = bestRoot(in: lhs, graph: graph, adjacency: adjacency)
            let right = bestRoot(in: rhs, graph: graph, adjacency: adjacency)
            return (left ?? 0) < (right ?? 0)
        }
    }

    private static func bestRoot(
        in component: Set<Int64>,
        graph: KnowledgeGraphSnapshot,
        adjacency: [Int64: Set<Int64>]
    ) -> Int64? {
        let timestamps = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.timestamp) })
        return component.max { lhs, rhs in
            let leftDegree = adjacency[lhs]?.count ?? 0
            let rightDegree = adjacency[rhs]?.count ?? 0
            if leftDegree == rightDegree {
                let leftTime = timestamps[lhs] ?? 0
                let rightTime = timestamps[rhs] ?? 0
                return leftTime == rightTime ? lhs > rhs : leftTime < rightTime
            }
            return leftDegree < rightDegree
        }
    }

    private static func mindMapPositions(
        components: [Set<Int64>],
        graph: KnowledgeGraphSnapshot,
        adjacency: [Int64: Set<Int64>],
        preferredRoot: Int64?
    ) -> [Int64: GraphPoint] {
        var result: [Int64: GraphPoint] = [:]
        var componentTop = 0.0
        for component in components {
            let root = (preferredRoot.flatMap { component.contains($0) ? $0 : nil })
                ?? bestRoot(in: component, graph: graph, adjacency: adjacency)
                ?? component.min()!
            var levels: [[Int64]] = []
            var visited: Set<Int64> = [root]
            var frontier = [root]
            while !frontier.isEmpty {
                levels.append(frontier)
                var next: [Int64] = []
                for node in frontier {
                    let neighbors = (adjacency[node] ?? [])
                        .filter { component.contains($0) && !visited.contains($0) }
                        .sorted { lhs, rhs in
                            let leftDegree = adjacency[lhs]?.count ?? 0
                            let rightDegree = adjacency[rhs]?.count ?? 0
                            return leftDegree == rightDegree ? lhs < rhs : leftDegree > rightDegree
                        }
                    for neighbor in neighbors where visited.insert(neighbor).inserted {
                        next.append(neighbor)
                    }
                }
                frontier = next
            }

            let widest = max(1, levels.map(\.count).max() ?? 1)
            let componentHeight = max(180, Double(widest - 1) * 92 + 160)
            let centerY = componentTop + componentHeight / 2
            for (depth, level) in levels.enumerated() {
                let levelHeight = Double(max(0, level.count - 1)) * 92
                for (index, nodeID) in level.enumerated() {
                    result[nodeID] = GraphPoint(
                        x: Double(depth) * 230,
                        y: centerY - levelHeight / 2 + Double(index) * 92
                    )
                }
            }
            componentTop += componentHeight + 120
        }
        return result
    }

    private static func networkPositions(
        components: [Set<Int64>],
        graph: KnowledgeGraphSnapshot,
        adjacency: [Int64: Set<Int64>],
        preferredRoot: Int64?
    ) -> [Int64: GraphPoint] {
        var result: [Int64: GraphPoint] = [:]
        let columns = max(1, Int(ceil(sqrt(Double(components.count)))))
        for (componentIndex, component) in components.enumerated() {
            let centerX = Double(componentIndex % columns) * 720
            let centerY = Double(componentIndex / columns) * 560
            let root = (preferredRoot.flatMap { component.contains($0) ? $0 : nil })
                ?? bestRoot(in: component, graph: graph, adjacency: adjacency)
                ?? component.min()!
            result[root] = GraphPoint(x: centerX, y: centerY)
            let remaining = component.filter { $0 != root }.sorted { lhs, rhs in
                let leftDegree = adjacency[lhs]?.count ?? 0
                let rightDegree = adjacency[rhs]?.count ?? 0
                return leftDegree == rightDegree ? lhs < rhs : leftDegree > rightDegree
            }
            var offset = 0
            var ring = 1
            while offset < remaining.count {
                let capacity = max(8, ring * 10)
                let count = min(capacity, remaining.count - offset)
                let radius = Double(ring) * 150
                for index in 0..<count {
                    let angle = -Double.pi / 2 + (2 * Double.pi * Double(index) / Double(count))
                    let nodeID = remaining[offset + index]
                    result[nodeID] = GraphPoint(
                        x: centerX + cos(angle) * radius,
                        y: centerY + sin(angle) * radius
                    )
                }
                offset += count
                ring += 1
            }
        }
        return result
    }

    private static func centered(_ positions: [Int64: GraphPoint]) -> [Int64: GraphPoint] {
        guard let minX = positions.values.map(\.x).min(),
              let maxX = positions.values.map(\.x).max(),
              let minY = positions.values.map(\.y).min(),
              let maxY = positions.values.map(\.y).max() else { return positions }
        let middleX = (minX + maxX) / 2
        let middleY = (minY + maxY) / 2
        return positions.mapValues { GraphPoint(x: $0.x - middleX, y: $0.y - middleY) }
    }
}
