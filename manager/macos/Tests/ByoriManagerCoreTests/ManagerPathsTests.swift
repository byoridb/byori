import XCTest
@testable import ByoriManagerCore

final class ManagerPathsTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testManagedFileInstallIsIdempotentAndBacksUpChanges() throws {
        let source = temporaryRoot.appendingPathComponent("source/SKILL.md")
        let destination = temporaryRoot.appendingPathComponent("home/.agents/skills/byori/SKILL.md")
        let backups = temporaryRoot.appendingPathComponent("backups")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("version-one".utf8).write(to: source)

        let installer = ManagedFileInstaller()
        XCTAssertTrue(try installer.install(source: source, destination: destination, backupRoot: backups))
        XCTAssertEqual(installer.state(source: source, destination: destination), .current)
        XCTAssertFalse(try installer.install(source: source, destination: destination, backupRoot: backups))

        try Data("version-two".utf8).write(to: source)
        XCTAssertEqual(installer.state(source: source, destination: destination), .outdated)
        XCTAssertTrue(try installer.install(source: source, destination: destination, backupRoot: backups))
        XCTAssertEqual(try Data(contentsOf: destination), Data("version-two".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
    }

    func testManagedFileRemoveCreatesBackup() throws {
        let destination = temporaryRoot.appendingPathComponent("home/.claude/skills/byori/SKILL.md")
        let backups = temporaryRoot.appendingPathComponent("backups")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(to: destination)

        let installer = ManagedFileInstaller()
        XCTAssertTrue(try installer.remove(destination: destination, backupRoot: backups))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
        XCTAssertFalse(try installer.remove(destination: destination, backupRoot: backups))
    }

    func testPathsUseCurrentCodexSkillLocation() {
        let paths = ManagerPaths(home: temporaryRoot, runtimeRoot: temporaryRoot)
        XCTAssertTrue(paths.codexSkill.path.hasSuffix("/.agents/skills/byoridb-memory/SKILL.md"))
        XCTAssertTrue(paths.legacyCodexSkill.path.hasSuffix("/.codex/skills/byoridb-memory/SKILL.md"))
    }

    func testKnowledgeGraphLayoutsAreDeterministicCompleteAndFinite() {
        let graph = makeKnowledgeGraph()

        for mode in KnowledgeGraphLayoutMode.allCases {
            let positions = KnowledgeGraphLayout.positions(for: graph, mode: mode, rootID: 1)
            let repeated = KnowledgeGraphLayout.positions(for: graph, mode: mode, rootID: 1)

            XCTAssertEqual(positions, repeated, "\(mode.rawValue) layout must be deterministic")
            XCTAssertEqual(Set(positions.keys), Set(graph.nodes.map(\.id)))
            XCTAssertTrue(positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
    }

    func testKnowledgeGraphRootSelectionAndMindMapDirection() throws {
        let graph = makeKnowledgeGraph()

        XCTAssertEqual(KnowledgeGraphLayout.suggestedRoot(for: graph), 1)
        XCTAssertEqual(KnowledgeGraphLayout.suggestedRoot(for: graph, preferred: 4), 4)

        let positions = KnowledgeGraphLayout.positions(for: graph, mode: .mindMap, rootID: 1)
        let root = try XCTUnwrap(positions[1])
        let child = try XCTUnwrap(positions[2])
        XCTAssertGreaterThan(child.x, root.x)
    }

    private func makeKnowledgeGraph() -> KnowledgeGraphSnapshot {
        KnowledgeGraphSnapshot(
            nodes: [
                KnowledgeNode(id: 1, name: "Root", kind: "concept", timestamp: 100),
                KnowledgeNode(id: 2, name: "Child", kind: "concept", timestamp: 200),
                KnowledgeNode(id: 3, name: "Sibling", kind: "concept", timestamp: 300),
                KnowledgeNode(id: 4, name: "Isolated", kind: "concept", timestamp: 400),
            ],
            edges: [
                KnowledgeEdge(source: 1, target: 2, kind: "contains"),
                KnowledgeEdge(source: 1, target: 3, kind: "contains"),
            ]
        )
    }
}
