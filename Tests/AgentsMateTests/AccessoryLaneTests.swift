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

    func testAccessoryIconInitialisers() {
        XCTAssertEqual(AgentLane.Accessory(symbol: "x", label: "L").icon, .symbol("x"))
    }
}

@MainActor
final class HeaderAlignmentTests: XCTestCase {
    func testHomeHeaderRunsDownToTheSidebarHeadersLine() {
        // The sidebar's header ends at y 136; the board's starts at 52 and has a 1 pt divider.
        XCTAssertEqual(AgentHomeView.headerHeight(top: 52, sidebarBottom: 136), 83)
        XCTAssertEqual(AgentHomeView.headerHeight(top: 52, sidebarBottom: 136) + 52 + 1, 136, "one divider line")
    }

    func testHomeHeaderKeepsItsOwnHeightWithNoSidebarOrAShorterOne() {
        XCTAssertEqual(AgentHomeView.headerHeight(top: 52, sidebarBottom: nil), AgentsModeMetrics.headerRowHeight)
        XCTAssertEqual(AgentHomeView.headerHeight(top: 52, sidebarBottom: 60), AgentsModeMetrics.headerRowHeight)
    }

}

@MainActor
final class AgentsCapsuleTests: XCTestCase {
    private func store() -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        let store = AgentLaneStore(configuration: config, backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-capsule-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "shell")])
        return store
    }

    func testTheIconIsOneSwappableValueAndTheTitleIsPlural() {
        XCTAssertEqual(AgentsToolbar.agentsIcon, .bundled("bot"))
        XCTAssertNotNil(LaneIconLibrary.bundledImage("bot"))
        XCTAssertEqual(AgentsToolbar.agentsTitle, "Agents")
        XCTAssertTrue(AgentsToolbar.windowItemLabels.contains("Agents"))
        XCTAssertEqual(AgentsToolbarAgent(isOn: false) {}.icon, AgentsToolbar.agentsIcon)
    }

    func testTheBundledBotIsLucideZeroFourSixtyAndDrawsAsATemplate() throws {
        let url = try XCTUnwrap(LaneIconLibrary.url(forBundled: "bot"))
        let svg = try String(contentsOf: url, encoding: .utf8)
        for shape in ["M12 8V4H8", "x=\"4\" y=\"8\" rx=\"2\"", "M2 14h2", "M20 14h2", "M15 13v2", "M9 13v2"] {
            XCTAssertTrue(svg.contains(shape), "bot.svg lost \(shape): not the 0.460.0 drawing")
        }
        XCTAssertTrue(svg.contains("stroke=\"currentColor\""), "it takes the label's colour")
    }

    func testEnteringAgentsModeSelectsAllAgentsAndLeavingDoesNot() {
        let store = store()
        store.open("a")
        XCTAssertFalse(store.isHomeShown)
        var on = false
        let off = AgentsToolbarAgent(isOn: false, store: store) { on = true }
        off.press()
        XCTAssertTrue(on)
        XCTAssertTrue(store.isHomeShown, "entering lands on All Agents")
        store.open("a")
        let leaving = AgentsToolbarAgent(isOn: true, store: store) { on = false }
        leaving.press()
        XCTAssertFalse(on)
        XCTAssertFalse(store.isHomeShown, "leaving only toggles the mode")
    }

    func testTheHelpNamesTheShortcutAndThereIsNoBadgeApi() {
        XCTAssertTrue(AgentsToolbarAgent(isOn: false) {}.help.contains("⇧⌘A"))
        XCTAssertTrue(AgentsToolbarAgent(isOn: true) {}.help.hasPrefix("Leave"))
    }

    func testTheStripDrawsTheCapsuleAtTheToggleHeight() throws {
        let strip = AgentsToolbarButton(AgentsToolbarAgent(isOn: true) {}, drawsGlass: false)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.height, AgentsToolbar.buttonHeight)
    }
}
