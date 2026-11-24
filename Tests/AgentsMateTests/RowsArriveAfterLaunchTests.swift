import XCTest
@testable import AgentsMate

@MainActor
final class RowsArriveAfterLaunchTests: XCTestCase {
    private func lane(_ id: String) -> AgentLane {
        AgentLane(id: id, title: id, directory: URL(fileURLWithPath: "/w/" + id), backendID: "codex", isClosable: false)
    }

    private func store(finds: Bool) -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: finds,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        let codex = CommandLaneBackend.tmuxLane(id: "codex", displayName: "Codex", command: "w", statusAgent: "codex",
                                                tmuxSessions: TmuxLaneSessions(prefixes: ["cx-"]))
        return AgentLaneStore(configuration: config, backends: [codex], statusFeed: nil,
                              defaults: UserDefaults(suiteName: "agentsmate-late-\(UUID().uuidString)")!)
    }

    func testRowsThatArriveAfterTheFirstSweepAskForAnother() async throws {
        let store = store(finds: true)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(store.sweepScheduled, "the first sweep has run")
        store.sync(lanes: [lane("a")])
        XCTAssertTrue(store.sweepScheduled, "new rows may widen what the app's scope admits")
    }

    func testNoSweepWhenDiscoveryIsOff() {
        let store = store(finds: false)
        store.sync(lanes: [lane("a")])
        XCTAssertFalse(store.sweepScheduled)
    }
}
