import XCTest
@testable import AgentsMate

final class PullRequestPillSettingTests: XCTestCase {
    func testPillsAreOffUnlessTheAppTurnsThemOn() {
        let off = AgentLaneStore.Configuration(termProgram: "T")
        XCTAssertFalse(off.showsPullRequestPills)
        let on = AgentLaneStore.Configuration(termProgram: "T", showsPullRequestPills: true)
        XCTAssertTrue(on.showsPullRequestPills)
    }

    @MainActor
    func testTheSidebarDefaultsCarryTheSetting() {
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                        sharedLanes: nil, liveSnapshotFile: nil, displayedExportFile: nil),
                                   backends: [], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-pills-\(UUID().uuidString)")!)
        XCTAssertFalse(store.sidebarDefaults.pullRequests)
        XCTAssertEqual(store.keys.showsPullRequestPills, store.keys.prefix + "showsPullRequestPills")
    }
}
