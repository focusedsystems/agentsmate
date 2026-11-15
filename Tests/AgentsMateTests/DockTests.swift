import XCTest
@testable import AgentsMate

@MainActor
final class DockTests: XCTestCase {
    func testShowHideAndShortcuts() {
        let defaults = UserDefaults(suiteName: "agentsmate-dock-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "T", shortcuts: .all, sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        XCTAssertFalse(store.handle(.togglePanel, from: "x"), "no dock open, the key goes on to the menus")
        store.showDock()
        XCTAssertTrue(store.dockVisible)
        XCTAssertEqual(store.lanes.count, 1, "showing an empty dock opens a lane")
        let id = store.lanes[0].id
        XCTAssertTrue(store.handle(.maximize, from: id))
        XCTAssertTrue(store.dockMaximized)
        XCTAssertTrue(store.handle(.togglePanel, from: id))
        XCTAssertFalse(store.dockVisible)
        store.showDock()
        XCTAssertTrue(store.dockMaximized, "the dock opens in the mode it was last in")
        store.detachAll()
    }
}

@MainActor
final class CloseHookTests: XCTestCase {
    func testKeepRowEndsTerminalButKeepsLane() {
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-close-\(UUID().uuidString)")!)
        store.add(AgentLane(id: "r", title: "Repo", backendID: "shell", isClosable: true), open: false)
        store.add(AgentLane(id: "s", title: "Scratch", backendID: "shell", isClosable: true), open: false)
        var told: [String] = []
        store.willCloseLane = { lane, _ in lane.id == "r" ? .keepRow : .remove }
        store.didCloseLane = { lane, decision in told.append("\(lane.id):\(decision)") }
        store.close("r")
        store.close("s")
        XCTAssertEqual(store.lanes.map(\.id), ["r"])
        XCTAssertNotNil(store.sessions["r"])
        XCTAssertEqual(told, ["r:keepRow", "s:remove"])
    }
}

@MainActor
final class AttentionTests: XCTestCase {
    func testUnreadAndJump() {
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil, notifies: true),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-att-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "shell"), AgentLane(id: "b", title: "B", backendID: "shell")])
        let b = store.sessions["b"]!
        b.update(record: LaneStatus(agent: "claude", state: .running, lane: "b", event: "UserPromptSubmit"))
        b.update(record: LaneStatus(agent: "claude", state: .permissionRequested, lane: "b", event: "Notification"))
        XCTAssertEqual(store.unreadLanes.map(\.id), ["b"])
        XCTAssertTrue(store.jumpToUnread())
        XCTAssertEqual(store.selectedID, "b")
        store.detachAll()
    }
}
import AgentsMateStatus

@MainActor
final class HistoryPaletteTests: XCTestCase {
    func testBackForwardAndPalette() {
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-hist-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "a", title: "Alpha", directory: URL(fileURLWithPath: "/w/alpha"), backendID: "shell"),
                           AgentLane(id: "b", title: "Beta", directory: URL(fileURLWithPath: "/w/beta"), backendID: "shell"),
                           AgentLane(id: "c", title: "Gamma", directory: URL(fileURLWithPath: "/w/gamma"), backendID: "shell")])
        store.open("a", focus: false); store.open("b", focus: false); store.open("c", focus: false)
        store.goBack()
        XCTAssertEqual(store.selectedID, "b")
        store.goBack()
        XCTAssertEqual(store.selectedID, "a")
        XCTAssertFalse(store.canGoBack)
        store.goForward()
        XCTAssertEqual(store.selectedID, "b")
        XCTAssertEqual(store.paletteResults("gam").map(\.id), ["c"])
        XCTAssertEqual(store.paletteResults("w beta").map(\.id), ["b"])
        XCTAssertEqual(store.paletteResults("").count, 3)
        store.detachAll()
    }
}
