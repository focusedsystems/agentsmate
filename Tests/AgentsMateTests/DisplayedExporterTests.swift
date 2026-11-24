import XCTest
@testable import AgentsMate
import AgentsMateStatus

@MainActor
final class DisplayedExporterTests: XCTestCase {
    private func lane(_ id: String, section: String?, folder: String = "/w") -> AgentLane {
        AgentLane(id: id, title: id.uppercased(), directory: URL(fileURLWithPath: folder + "/" + id), backendID: "agent",
                  section: section)
    }

    private func store(scope: (@Sendable (String?, String?) -> Bool)? = nil) -> AgentLaneStore {
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        config.sessionScope = scope
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend.tmuxLane(id: "agent", displayName: "Agent", command: "true",
                                                                          statusAgent: "claude", tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"]))],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-displayed-\(UUID().uuidString)")!)
        store.sync(lanes: [lane("api", section: "Platform"), lane("web", section: "Platform"), lane("dns", section: "Cloud"),
                           lane("infra", section: "Cloud")])
        return store
    }

    func testRowsFollowTheSidebarOrderWithTheirHeadings() {
        let export = store().displayedExport()
        XCTAssertEqual(export.rows.map(\.laneID), ["api", "web", "dns", "infra"])
        XCTAssertEqual(export.rows.map(\.section), ["Platform", "Platform", "Cloud", "Cloud"])
        XCTAssertEqual(export.rows.map(\.state), Array(repeating: .notAttached, count: 4))
        XCTAssertEqual(export.rows.first?.backend, "tmux")
        XCTAssertEqual(export.rows.first?.agent, "claude")
        XCTAssertEqual(export.rows.first?.folder, "/w/api")
        XCTAssertTrue(export.rows.allSatisfy { !$0.attached && $0.isTopLevel && !$0.isParallel && !$0.collapsed })
        XCTAssertEqual(export.counts, .init())
    }

    func testHeadingsAreNullWhenTheListIsFlatAndSelectionIsMarked() {
        let store = store()
        store.defaults.set(false, forKey: store.keys.showsSectionHeadings)
        store.open("web")
        let export = store.displayedExport()
        XCTAssertTrue(export.rows.allSatisfy { $0.section == nil })
        XCTAssertEqual(export.rows.filter(\.selected).map(\.laneID), ["web"])
    }

    func testARowTheSearchHidesIsNotExported() {
        let store = store()
        store.displayedSidebarSearch = "api"
        var export = store.displayedExport()
        XCTAssertEqual(export.rows.map(\.laneID), ["api"])
        XCTAssertEqual(export.filter.sidebarSearch, "api")
        store.displayedSidebarSearch = "cloud"
        export = store.displayedExport()
        XCTAssertEqual(export.rows.map(\.laneID), ["dns", "infra"], "a section name finds its lanes, as in the sidebar")
        store.displayedSidebarSearch = ""
        store.defaults.set(true, forKey: store.keys.filterRunning)
        export = store.displayedExport()
        XCTAssertEqual(export.rows, [], "a chip that nothing passes leaves nothing")
        XCTAssertEqual(export.filter.statuses, ["running"])
    }

    func testASessionOutsideTheScopeNeverBecomesARow() {
        let store = store(scope: { directory, _ in directory?.hasPrefix("/w/") == true })
        store.received(found: [
            .init(backendID: "agent", session: DiscoveredSession(kind: "tmux", name: "lane-in", directory: "/w/in")),
            .init(backendID: "agent", session: DiscoveredSession(kind: "tmux", name: "lane-out", directory: "/private/out")),
        ])
        let export = store.displayedExport()
        XCTAssertFalse(export.rows.contains { $0.sessionName == "lane-out" || $0.folder == "/private/out" })
        XCTAssertFalse(export.allAgents.contains { $0.sessionName == "lane-out" })
    }

    func testChangesWithinTheDelayShareOneWrite() async throws {
        let store = store()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("exporter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("displayed.json")
        let exporter = DisplayedExporter(store: store, url: url, delay: 0.15)
        for i in 0..<20 {
            store.displayedSidebarSearch = i % 2 == 0 ? "a" : ""
            exporter.changed()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing is written before the delay is up")
        try await waitUntil { exporter.writes >= 1 }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(exporter.writes, 1)
        XCTAssertEqual(DisplayedExport.load(url)?.rows.count, 4)

        store.displayedSidebarSearch = "api"
        exporter.changed()
        try await waitUntil { exporter.writes >= 2 }
        XCTAssertEqual(exporter.writes, 2)
        XCTAssertEqual(DisplayedExport.load(url)?.rows.map(\.laneID), ["api"])

        exporter.changed()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(exporter.writes, 2, "a change that shows nothing new is not written")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    func testNilFileTurnsTheExportOff() {
        let store = store()
        XCTAssertNil(store.configuration.displayedExportFile)
        XCTAssertNil(store.displayedExporter)
    }
}
