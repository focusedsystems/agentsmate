import XCTest
import AgentsMateStatus
@testable import AgentsMate

@MainActor
final class OpenSessionByIDTests: XCTestCase {
    private let full = "3f2a9c1e-7b4d-4e8a-9c2f-1a2b3c4d5e6f"

    private func list(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("claude-agents.json")
        let json = """
        [{"id":"ab12cd34","sessionId":"\(full)","name":"docs","cwd":"/tmp","kind":"background","state":"idle"}]
        """
        try Data(json.utf8).write(to: url)
        return url
    }

    private func store(cache: URL) -> AgentLaneStore {
        var backend = ClaudeBackgroundLaneBackend(id: "claude-bg", displayName: "Claude (Background)")
        backend.agentsListCache = cache
        backend.discoversSessions = false
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, notifies: false,
                                                  findsDetachedSessions: false, sharedLanes: nil,
                                                  liveSnapshotFile: nil, opensActiveOnly: false, displayedExportFile: nil)
        config.defaultsPrefix = "byid.\(UUID().uuidString)."
        return AgentLaneStore(configuration: config, backends: [backend], statusFeed: nil,
                              defaults: UserDefaults(suiteName: "agentsmate-byid-\(UUID().uuidString)")!)
    }

    func testTheIdIsTakenFromWhatWasPasted() {
        XCTAssertEqual(AgentLaneStore.sessionID(in: "ab12cd34"), "ab12cd34")
        XCTAssertEqual(AgentLaneStore.sessionID(in: "  claude attach ab12cd34\n"), "ab12cd34")
        XCTAssertEqual(AgentLaneStore.sessionID(in: "`\(full)`"), full)
        XCTAssertNil(AgentLaneStore.sessionID(in: ""))
        XCTAssertNil(AgentLaneStore.sessionID(in: "not/an id!"))
    }

    func testAPastedIdOpensALaneAttachedToThatSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = store(cache: try list(dir))
        guard case .opened(let id) = store.openSession(id: "claude attach ab12cd34", in: "Work") else {
            return XCTFail("the session should open")
        }
        let lane = try XCTUnwrap(store.lanes.first { $0.id == id })
        XCTAssertEqual(lane.agentSessionID, "ab12cd34")
        XCTAssertEqual(lane.agentConversationID, full)
        XCTAssertEqual(lane.title, "docs")
        XCTAssertEqual(lane.section, "Work")
        XCTAssertTrue(lane.isClosable)
        // The same session again, by its full id: the row it is already in.
        XCTAssertEqual(store.openSession(id: full, in: nil), .opened(id))
        XCTAssertEqual(store.lanes.count, 1)
        store.detachAll()
    }

    func testAnIdNoSessionHasOpensNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = store(cache: try list(dir))
        XCTAssertEqual(store.openSession(id: "zz99", in: nil), .notFound("zz99"))
        XCTAssertEqual(store.openSession(id: "???", in: nil), .invalid)
        XCTAssertTrue(store.lanes.isEmpty)
    }
}
