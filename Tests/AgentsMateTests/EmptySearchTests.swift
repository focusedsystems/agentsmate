import XCTest
import SwiftUI
@testable import AgentsMate

@MainActor
final class EmptySearchTests: XCTestCase {
    private func store() -> AgentLaneStore {
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                        sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                        displayedExportFile: nil),
                                   backends: [CommandLaneBackend(id: "agent", displayName: "Agent", command: "true")],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-empty-\(UUID().uuidString)")!)
        store.sync(lanes: ["api", "web"].map {
            AgentLane(id: $0, title: $0.uppercased(), directory: URL(fileURLWithPath: "/w/" + $0), backendID: "agent")
        })
        return store
    }

    func testASearchWithNoMatchShowsEveryLane() {
        let store = store()
        typealias Sidebar = AgentLaneSidebar<EmptyView>
        XCTAssertEqual(Sidebar.visibleLanes(store: store, query: "api", filters: []).map(\.id), ["api"])
        XCTAssertEqual(Sidebar.visibleLanes(store: store, query: "zzz", filters: []).map(\.id), ["api", "web"])
        XCTAssertEqual(Sidebar.visibleLanes(store: store, query: "zzz", filters: [.running]).map(\.id), ["api", "web"])
    }

    func testAFilterAloneIsLeftToTheFiltersOwnRule() {
        let store = store()
        XCTAssertEqual(AgentLaneSidebar<EmptyView>.visibleLanes(store: store, query: "", filters: [.running]), [])
    }

    func testASearchTheFiltersHideDropsTheFiltersAndKeepsTheSearch() {
        let store = store()
        typealias Sidebar = AgentLaneSidebar<EmptyView>
        XCTAssertEqual(Sidebar.visibleLanes(store: store, query: "api", filters: [.running]).map(\.id), ["api"])
        XCTAssertEqual(Sidebar.visibleLanes(store: store, query: "api", filters: [.running, .idle]).map(\.id), ["api"])
    }
}
