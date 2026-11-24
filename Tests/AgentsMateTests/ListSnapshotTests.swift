import XCTest
@testable import AgentsMate
import AgentsMateStatus

@MainActor
final class ListSnapshotTests: XCTestCase {
    private func lane(_ id: String, section: String?) -> AgentLane {
        AgentLane(id: id, title: id.uppercased(), directory: URL(fileURLWithPath: "/w/" + id), backendID: "agent", section: section)
    }

    private func store(lanes: [AgentLane]? = nil) -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false)
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend(id: "agent", displayName: "Agent", command: "true")],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-snapshot-\(UUID().uuidString)")!)
        store.sync(lanes: lanes ?? [lane("api", section: "Platform"), lane("web", section: "Platform"),
                                    lane("infra", section: "Cloud"), lane("dns", section: "Cloud"), lane("misc", section: nil)])
        return store
    }

    /// The cached snapshot is the one worked out from scratch.
    private func assertFresh(_ store: AgentLaneStore, file: StaticString = #filePath, line: UInt = #line) {
        let cached = store.listSnapshot
        let fresh = store.buildListSnapshot()
        XCTAssertEqual(cached, fresh, file: file, line: line)
        XCTAssertEqual(store.groups, fresh.groups, file: file, line: line)
        XCTAssertEqual(store.numberedLanes, fresh.numberedLanes, file: file, line: line)
        XCTAssertEqual(store.sectionNames, fresh.sectionNames, file: file, line: line)
        XCTAssertEqual(fresh.collapseKeys, Set(fresh.groups.map(\.collapseKey)), file: file, line: line)
        XCTAssertEqual(fresh.regularGroupCount, fresh.groups.filter { !$0.isPinned && !$0.isDetached }.count,
                       file: file, line: line)
        XCTAssertEqual(fresh.shortcutNumbers,
                       Dictionary(uniqueKeysWithValues: fresh.numberedLanes.enumerated().map { ($1.id, $0 + 1) }),
                       file: file, line: line)
    }

    /// Run `change`, then check the snapshot was worked out again and still
    /// matches a fresh one.
    private func assertRebuilds(_ store: AgentLaneStore, _ what: String, _ change: () -> Void,
                                file: StaticString = #filePath, line: UInt = #line) {
        _ = store.listSnapshot
        let before = store.listSnapshotBuilds
        change()
        assertFresh(store, file: file, line: line)
        XCTAssertEqual(store.listSnapshotBuilds, before + 1, "\(what) invalidates the snapshot", file: file, line: line)
    }

    func testReadingAgainDoesNotRebuild() {
        let store = store()
        assertFresh(store)
        let builds = store.listSnapshotBuilds
        for _ in 0..<50 {
            _ = store.groups
            _ = store.numberedLanes
            _ = store.sectionNames
            _ = store.canCollapseOtherSections(than: store.groups[0])
        }
        XCTAssertEqual(store.listSnapshotBuilds, builds)
    }

    func testEachInputInvalidates() {
        let store = store()
        assertRebuilds(store, "pinning") { store.setPinned("dns", true) }
        XCTAssertEqual(store.numberedLanes.map(\.id), ["dns"])
        assertRebuilds(store, "moving a lane") { store.move("misc", to: "Cloud") }
        assertRebuilds(store, "a new section order") { store.setSectionOrder(["Cloud", "Platform"]) }
        XCTAssertEqual(store.sectionNames.prefix(2), ["Cloud", "Platform"])
        assertRebuilds(store, "a manual move") { store.moveLane("web", before: "api") }
        assertRebuilds(store, "collapsing") { store.toggleCollapsed("Cloud") }
        XCTAssertTrue(store.canCollapseOtherSections(than: store.groups[0]))
        assertRebuilds(store, "collapsing the others") { store.collapseOtherSections(than: store.groups[0]) }
        XCTAssertFalse(store.canCollapseOtherSections(than: store.groups[0]))
        assertRebuilds(store, "the app's order") { store.defaultRepositoryOrder = ["/w/infra", "/w/api"] }
        assertRebuilds(store, "the lanes") {
            store.sync(lanes: [lane("api", section: "Platform"), lane("infra", section: "Cloud"), lane("new", section: "Fresh")])
        }
        XCTAssertTrue(store.sectionNames.contains("Fresh"))
        assertRebuilds(store, "the sort") { store.setSort(.recentFirst) }
    }

    func testActivityReordersUnderARecencySort() {
        let store = store()
        store.setSort(.recentFirst)
        assertFresh(store)
        let builds = store.listSnapshotBuilds
        _ = store.groups
        XCTAssertEqual(store.listSnapshotBuilds, builds, "unchanged activity reuses the snapshot")
        let session = try! XCTUnwrap(store.sessions["web"])
        session.update(record: LaneStatus(agent: "claude", state: .running, event: "test", updatedAt: Date()))
        assertFresh(store)
        XCTAssertEqual(store.listSnapshotBuilds, builds + 1)
        XCTAssertEqual(store.groups.first { $0.section == "Platform" }?.lanes.first?.id, "web")
    }

    func testActivityIsIgnoredWhileSortedBySection() {
        let store = store()
        assertFresh(store)
        let builds = store.listSnapshotBuilds
        store.sessions["web"]?.update(record: LaneStatus(agent: "claude", state: .running, event: "test", updatedAt: Date()))
        _ = store.groups
        XCTAssertEqual(store.listSnapshotBuilds, builds)
    }

    func testTheSidebarIsAtLeastItsBaseWidth() {
        XCTAssertEqual(AgentLaneStore.sidebarMinimumWidth(chips: 0, controls: 0), 360)
        XCTAssertEqual(AgentLaneStore.sidebarMinimumWidth(chips: 230, controls: 140), 410)
        XCTAssertEqual(store().sidebarMinimumWidth, 360)
    }

    /// Three hundred lanes in ten sections, some pinned, ordered by the app:
    /// working the list out is quick, and reading it again is quicker still.
    func testManyLanesGroupQuickly() {
        let lanes = (0..<300).map { lane("repo\($0)", section: "Section \($0 % 10)") }
        let store = store(lanes: lanes)
        store.defaultRepositoryOrder = lanes.reversed().map(\.path)
        for id in ["repo3", "repo50", "repo120"] { store.setPinned(id, true) }
        _ = store.listSnapshot

        var start = Date()
        for _ in 0..<10 { _ = store.buildListSnapshot() }
        let build = Date().timeIntervalSince(start) / 10
        XCTAssertLessThan(build, 0.05, "one build took \(build * 1000) ms")

        start = Date()
        for _ in 0..<1000 {
            _ = store.groups
            _ = store.numberedLanes
            _ = store.canCollapseOtherSections(than: store.groups[1])
        }
        let reads = Date().timeIntervalSince(start)
        XCTAssertLessThan(reads, 0.25, "1000 reads took \(reads * 1000) ms")
        XCTAssertEqual(store.groups.filter { !$0.isPinned }.count, 10)
        XCTAssertEqual(store.numberedLanes.map(\.id), ["repo120", "repo50", "repo3"])
    }
}
