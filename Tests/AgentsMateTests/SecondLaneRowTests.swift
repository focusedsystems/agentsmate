import XCTest
@testable import AgentsMate
import AgentsMateStatus

@MainActor
final class SecondLaneRowTests: XCTestCase {
    private let root = "/w/Projects"

    private func store(named: Bool = true) -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, sharedLanes: nil,
                                                  liveSnapshotFile: nil, opensActiveOnly: false, displayedExportFile: nil)
        let codex = CommandLaneBackend.tmuxLane(
            id: "codex", displayName: "Codex", command: "codex-remote", statusAgent: "codex", variantFlag: "-n",
            tmuxSessions: TmuxLaneSessions(prefixes: ["cx-"], sessionName: named ? TmuxLaneSessions.folderSessionName(prefix: "cx-") : nil))
        let store = AgentLaneStore(configuration: config, backends: [codex], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-second-\(UUID().uuidString)")!)
        for name in ["Vantage", "Midpoint"] {
            store.add(AgentLane(id: name, title: name, directory: URL(fileURLWithPath: "\(root)/\(name)"), backendID: "codex",
                                isClosable: false), open: false)
        }
        return store
    }

    private func found(_ name: String, _ folder: String) -> DetachedSessions.Found {
        .init(backendID: "codex", session: DiscoveredSession(kind: "tmux", name: name, directory: "\(root)/\(folder)"))
    }

    func testASecondSessionInAFolderShowsAsItsOwnRow() {
        let store = store()
        store.received(found: [found("cx-vantage", "Vantage"), found("cx-vantage-2", "Vantage")])
        let names = store.displayedExport().rows.map { $0.sessionName ?? "" }.sorted()
        XCTAssertEqual(names, ["cx-midpoint", "cx-vantage", "cx-vantage-2"])
    }

    func testASessionAloneNamedForASecondLaneIsNotTakenByTheFoldersRow() {
        let store = store()
        store.received(found: [found("cx-midpoint-2", "Midpoint")])
        let rows = store.displayedExport().rows
        XCTAssertTrue(rows.contains { $0.sessionName == "cx-midpoint-2" })
        XCTAssertEqual(rows.first { $0.sessionName == "cx-midpoint" }?.state, .notAttached)
        let second = store.lanes.first { store.isDetached($0.id) }
        XCTAssertEqual(second?.sessionName, "cx-midpoint-2")
    }
}

extension SecondLaneRowTests {
    func testARowWithNoSessionNameDoesNotTakeASecondLanesSession() {
        let a = store(named: false)
        a.received(found: [found("cx-vantage", "Vantage"), found("cx-vantage-2", "Vantage")])
        XCTAssertTrue(a.displayedExport().rows.contains { $0.sessionName == "cx-vantage-2" })
        let b = store(named: false)
        b.received(found: [found("cx-midpoint-2", "Midpoint")])
        let rows = b.displayedExport().rows
        XCTAssertTrue(rows.contains { $0.sessionName == "cx-midpoint-2" }, "a lone second-lane session still gets its row")
        XCTAssertEqual(b.lanes.first { b.isDetached($0.id) }?.sessionName, "cx-midpoint-2")
    }

    func testAFolderNamedWithANumberStillOwnsItsLoneSession() {
        XCTAssertFalse(DetachedSessions.isSecondLaneName("cx-api-2", folder: "/w/API-2"))
        XCTAssertTrue(DetachedSessions.isSecondLaneName("cx-api-2-3", folder: "/w/API-2"))
        XCTAssertFalse(DetachedSessions.isSecondLaneName("cx-api", folder: "/w/api"))
        XCTAssertFalse(DetachedSessions.isSecondLaneName("cx-api-1", folder: "/w/api"))
    }
}
