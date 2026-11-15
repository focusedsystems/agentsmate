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
