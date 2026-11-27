import XCTest
@testable import AgentsMate

@MainActor
final class DuplicateLaneTests: XCTestCase {
    private func codex() -> CommandLaneBackend {
        .tmuxLane(id: "cmd:codex-remote", displayName: "Codex", command: "codex-remote", statusAgent: "codex",
                  variantFlag: "-n",
                  tmuxSessions: TmuxLaneSessions(prefixes: ["cx-"], sessionName: TmuxLaneSessions.folderSessionName(prefix: "cx-")))
    }

    private func store() -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        return AgentLaneStore(configuration: config, backends: [codex()], statusFeed: nil,
                              defaults: UserDefaults(suiteName: "agentsmate-dups-\(UUID().uuidString)")!)
    }

    private func entry(_ id: String, order: Int, variant: String? = nil, dir: String = "~/w/Munki",
                       title: String? = nil, updated: Date = Date(timeIntervalSince1970: 1_000)) -> SharedLaneList.Lane {
        SharedLaneList.Lane(id: id, title: title, directory: dir, backendID: "cmd:codex-remote", command: "codex-remote",
                            variantFlag: "-n", variant: variant, order: order, updated: updated)
    }

    func testMergeKeepsTheOldestOfRowsOnOneSession() {
        let list = SharedLaneList(lanes: [entry("b", order: 2), entry("a", order: 1), entry("c", order: 3),
                                          entry("other", order: 4, dir: "~/w/Intune"),
                                          entry("second", order: 5, variant: "2")], closed: [])
        let merged = SharedLaneList.merge([list], now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(merged.lanes.map(\.id), ["a", "other", "second"])
        XCTAssertEqual(Set(merged.closed.map(\.id)), ["b", "c"], "the others are told to drop them")
        let again = SharedLaneList.merge([merged, list], now: Date(timeIntervalSince1970: 2_001))
        XCTAssertEqual(again.lanes.map(\.id), ["a", "other", "second"], "a stale copy cannot bring them back")
    }

    func testRowsWithOneSessionNameOrAgentIDAreOneRow() {
        var a = entry("a", order: 1, dir: "~/w/A")
        var b = entry("b", order: 2, dir: "~/w/B")
        a.sessionName = "cx-x"; b.sessionName = "cx-x"
        XCTAssertEqual(SharedLaneList.duplicates(in: [a, b]), ["b": "a"])
        var c = entry("c", order: 3, dir: "~/w/C"), d = entry("d", order: 4, dir: "~/w/D")
        c.agentSessionID = "01a2"; d.agentSessionID = "01a2"
        XCTAssertEqual(SharedLaneList.duplicates(in: [c, d]), ["d": "c"])
        var overlay = entry("o", order: 5); overlay.overlay = true
        XCTAssertTrue(SharedLaneList.duplicates(in: [entry("p", order: 1), overlay]).isEmpty)
    }

    func testASharedListWithDuplicatesMakesOneRow() {
        let store = store()
        let list = SharedLaneList(lanes: (1...7).map { entry("id\($0)", order: $0) }, closed: [])
        store.applyShared(list, captured: [], skipping: [])
        XCTAssertEqual(store.lanes.map(\.id), ["id1"])
        store.detachAll()
    }

    func testLoadRepairsDuplicateRowsAlreadyHere() {
        let store = store()
        let dir = URL(fileURLWithPath: "/w/Munki")
        store.sync(lanes: ["old", "new1", "new2"].map {
            AgentLane(id: $0, title: "x", directory: dir, backendID: "cmd:codex-remote", isClosable: true)
        })
        store.sync(lanes: [])
        XCTAssertEqual(store.lanes.count, 3, "opened by the person, so they stay")
        store.applyShared(SharedLaneList(lanes: [], closed: []), captured: [], skipping: [])
        XCTAssertEqual(store.lanes.map(\.id), ["old"])
        store.detachAll()
    }

    func testANewLaneInAnOccupiedFolderGetsTheNextVariant() {
        let store = store()
        let dir = URL(fileURLWithPath: "/w/Munki")
        for id in ["a", "b", "c"] {
            store.add(AgentLane(id: id, title: id, directory: dir, backendID: "cmd:codex-remote", isClosable: true),
                      focus: false, open: false)
        }
        XCTAssertEqual(store.lanes.map(\.variant), [nil, "2", "3"])
        store.detachAll()
    }

    func testARowKeepsItsTitleWhenAnotherRowAttachesTheSameSession() {
        let store = store()
        let dir = URL(fileURLWithPath: "/w/Munki")
        store.sync(lanes: [AgentLane(id: "a", title: "A", directory: dir, backendID: "cmd:codex-remote", isClosable: true),
                           AgentLane(id: "b", title: "B", directory: dir, backendID: "cmd:codex-remote", isClosable: true)])
        for _ in 0..<3 { store.adopt(sessionTitle: "Fix Install Errors", for: "a") }
        XCTAssertNil(store.sessions["a"]?.customTitle)
        XCTAssertNil(store.sessions["b"]?.customTitle)
        store.detachAll()
    }

    func testAGeneratedRowIsNeverCollapsedAndWinsOverAUserLane() {
        let rows = [entry("a", order: 1), entry("repo:munki", order: 2), entry("b", order: 3)]
        XCTAssertEqual(SharedLaneList.duplicates(in: rows, generated: ["repo:munki"]), ["a": "repo:munki", "b": "repo:munki"])
        XCTAssertTrue(SharedLaneList.duplicates(in: [entry("repo:1", order: 1), entry("repo:2", order: 2)],
                                                generated: ["repo:1", "repo:2"]).isEmpty)
        let merged = SharedLaneList.merge([SharedLaneList(lanes: rows, closed: [])], now: Date(timeIntervalSince1970: 2_000),
                                          generated: ["repo:munki"])
        XCTAssertEqual(merged.lanes.map(\.id), ["repo:munki"])
        XCTAssertFalse(merged.closed.map(\.id).contains("repo:munki"))
    }

    func testTheStoreKeepsARowTheAppListsAndClosesTheUserLaneBesideIt() {
        let store = store()
        let dir = URL(fileURLWithPath: "/w/Munki")
        store.sync(lanes: [AgentLane(id: "repo:munki", title: "Munki", directory: dir, backendID: "cmd:codex-remote", isClosable: true)])
        let list = SharedLaneList(lanes: [entry("user", order: 0, dir: "/w/Munki"), entry("repo:munki", order: 1, dir: "/w/Munki")],
                                  closed: [.init(id: "repo:munki", at: Date(timeIntervalSince1970: 5_000))])
        store.applyShared(list, captured: [], skipping: [])
        XCTAssertEqual(store.lanes.map(\.id), ["repo:munki"], "never closed, and the user lane is not added beside it")
        store.detachAll()
    }
}
