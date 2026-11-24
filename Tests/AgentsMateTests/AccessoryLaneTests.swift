import XCTest
import SwiftUI
import AgentsMateStatus
@testable import AgentsMate

@MainActor
final class AccessoryLaneTests: XCTestCase {
    private func store(_ defaults: UserDefaults? = nil) -> AgentLaneStore {
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, notifies: true,
                                                  findsDetachedSessions: false, sharedLanes: nil,
                                                  liveSnapshotFile: nil, opensActiveOnly: false, displayedExportFile: nil)
        config.defaultsPrefix = "accessory."
        return AgentLaneStore(configuration: config, backends: [CommandLaneBackend.shell], statusFeed: nil,
                              defaults: defaults ?? UserDefaults(suiteName: "agentsmate-accessory-\(UUID().uuidString)")!)
    }

    private func lanes() -> [AgentLane] {
        var hub = AgentLane(id: "hub", title: "Hub", backendID: "shell")
        hub.accessory = .init(symbol: "cpu", label: "Hub agents")
        return [hub, AgentLane(id: "a", title: "A", backendID: "shell"), AgentLane(id: "b", title: "B", backendID: "shell")]
    }

    func testAccessoryLaneIsNotListed() {
        let store = store()
        store.sync(lanes: lanes())
        XCTAssertEqual(store.lanes.map(\.id), ["hub", "a", "b"])
        XCTAssertEqual(store.listedLanes.map(\.id), ["a", "b"])
        XCTAssertEqual(store.accessoryLanes.map(\.id), ["hub"])
        XCTAssertEqual(store.displayOrder.map(\.id), ["a", "b"])
        XCTAssertEqual(store.listSnapshot.orderedLanes.map(\.id), ["a", "b"])
        XCTAssertEqual(store.selectedID, "a", "the first listed lane is selected, not the accessory")
        store.detachAll()
    }

    func testOpeningItShowsItsPaneAndLeavesTheList() {
        let store = store()
        store.sync(lanes: lanes())
        XCTAssertFalse(store.isShowingAccessory("hub"))
        store.open("hub", focus: false)
        XCTAssertTrue(store.isShowingAccessory("hub"))
        XCTAssertTrue(store.selected?.lane.accessory != nil)
        store.open("a", focus: false)
        XCTAssertFalse(store.isShowingAccessory("hub"))
        store.showHome()
        store.open("hub", focus: false)
        XCTAssertTrue(store.isShowingAccessory("hub"), "opening it leaves All Agents")
        store.detachAll()
    }

    func testItIsOutOfTheExportCountsAndBadge() {
        let store = store()
        store.sync(lanes: lanes())
        let hub = store.sessions["hub"]!
        hub.update(record: LaneStatus(agent: "claude", state: .running, lane: "hub", event: "UserPromptSubmit"))
        hub.update(record: LaneStatus(agent: "claude", state: .done, lane: "hub", event: "Stop",
                                      updatedAt: Date(timeIntervalSinceNow: 1)))
        XCTAssertTrue(hub.needsAttention)
        store.updateBadge()
        XCTAssertEqual(store.badgeCount, 0)
        XCTAssertEqual(store.unreadLanes.map(\.id), [])
        store.open("hub", focus: false)
        let export = store.displayedExport()
        XCTAssertEqual(export.rows.map(\.laneID), ["a", "b"])
        XCTAssertFalse(export.rows.contains { $0.selected }, "its pane is not a row")
        XCTAssertFalse(export.allAgents.contains { $0.laneID == "hub" })
        XCTAssertEqual(export.counts, .init())
        XCTAssertEqual(AgentLaneSidebar<EmptyView>.visibleLanes(store: store, query: "", filters: []).map(\.id), ["a", "b"])
        store.detachAll()
    }

    func testSelectionSurvivesRestore() {
        let defaults = UserDefaults(suiteName: "agentsmate-accessory-\(UUID().uuidString)")!
        let first = store(defaults)
        first.sync(lanes: lanes())
        first.open("hub", focus: false)
        first.detachAll()
        let second = store(defaults)
        second.sync(lanes: lanes())
        XCTAssertEqual(second.selectedID, "hub")
        XCTAssertTrue(second.isShowingAccessory("hub"))
        second.detachAll()
    }

    func testAllAgentsGlyphIsNotTheAppsRobot() {
        XCTAssertEqual(AgentHomeSidebarButton.icon, .symbol("square.grid.2x2"))
        XCTAssertEqual(AgentLane.Accessory(symbol: "x", label: "L").icon, .symbol("x"))
    }
}
