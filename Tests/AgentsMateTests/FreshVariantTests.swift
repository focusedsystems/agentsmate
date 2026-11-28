import XCTest
@testable import AgentsMate

@MainActor
final class FreshVariantTests: XCTestCase {
    private func backend() -> CommandLaneBackend {
        .tmuxLane(id: "app.codex", displayName: "Codex", command: "codex-remote", statusAgent: "codex", variantFlag: "-n",
                  tmuxSessions: TmuxLaneSessions(prefixes: ["cx-"], sessionName: TmuxLaneSessions.folderSessionName(prefix: "cx-")))
    }

    private func store(occupied: (@Sendable (String, String, String?) -> Bool)? = nil) -> AgentLaneStore {
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        config.variantOccupied = occupied
        let store = AgentLaneStore(configuration: config, backends: [backend()], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-fresh-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "row", title: "Munki", directory: URL(fileURLWithPath: "/w/Munki"), backendID: "app.codex")])
        return store
    }

    func testAVariantWhoseSessionIsLiveElsewhereIsSkipped() throws {
        let store = store { _, name, _ in name == "cx-munki-2" }
        XCTAssertEqual(try XCTUnwrap(store.duplicate("row", focus: false)).lane.variant, "3")
        store.detachAll()
    }

    func testAVariantAResumeEntryStillNamesIsSkipped() throws {
        let ledger: Set<String> = ["cx-munki-2", "cx-munki-3"]
        let store = store { _, name, host in ledger.contains(name) && host == nil }
        XCTAssertEqual(try XCTUnwrap(store.duplicate("row", focus: false)).lane.variant, "4")
        store.detachAll()
    }

    func testAClosedLanesVariantIsNotReused() throws {
        let store = store()
        let first = try XCTUnwrap(store.duplicate("row", focus: false))
        XCTAssertEqual(first.lane.variant, "2")
        store.close(first.lane.id)
        XCTAssertEqual(try XCTUnwrap(store.duplicate("row", focus: false)).lane.variant, "3")
        store.detachAll()
    }

    func testANewLaneAsksTheWrapperForAFreshSession() throws {
        let store = store()
        XCTAssertTrue(try XCTUnwrap(store.duplicate("row", focus: false)).lane.startsNewSession)
        XCTAssertFalse(try XCTUnwrap(store.sessions["row"]).lane.startsNewSession, "the first lane is left as it was")
        store.detachAll()
    }
}
