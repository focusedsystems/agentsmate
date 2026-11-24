import XCTest
import AgentsMateStatus
@testable import AgentsMate

private struct StubSource: LaneStatusSource {
    var list: [LaneStatus]
    func records() async -> [LaneStatus] { list }
}

@MainActor
final class ListedSessionTests: XCTestCase {
    private let full = "58a5ca90-0e55-4f6e-b49c-b599f3fb82b1"

    private func makeStore(hook: LaneStatus?) async throws -> AgentLaneStore {
        let polled = LaneStatus(agent: "claude", state: .waitingForInput, lane: "Intune · Pipeline", directory: "/w/Intune",
                                sessionID: full, message: ClaudeAgentsList.backgroundMessage, event: ClaudeAgentsList.event,
                                updatedAt: Date(timeIntervalSinceNow: -5), agentID: "58a5ca90")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString)")
        let feed = LaneStatusFeed(directory: LaneStatusDirectory(url: dir),
                                  sources: [StubSource(list: [polled] + [hook].compactMap { $0 })])
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: true,
                                                  displayedExportFile: nil)
        let store = AgentLaneStore(configuration: config, backends: [CommandLaneBackend(id: "default", displayName: "Default", command: "")],
                                   statusFeed: feed, defaults: UserDefaults(suiteName: "agentsmate-listed-\(UUID().uuidString)")!)
        var lane = AgentLane(id: "intune", title: "Intune", directory: URL(fileURLWithPath: "/w/Intune"), backendID: "default", statusMatch: .session(full),
                             section: "Devices")
        lane.agentSessionID = "58a5ca90"
        store.sync(lanes: [lane])
        feed.start()
        for _ in 0..<200 where store.sessions["intune"]?.record == nil { try await Task.sleep(for: .milliseconds(20)) }
        return store
    }

    func testAHooksQuestionDoesNotHideThatTheDaemonStillListsTheSession() async throws {
        let question = LaneStatus(agent: "claude", state: .waitingForInput, lane: "intune", directory: "/w/Intune",
                                  sessionID: full, message: "Wipe the iPads?", event: "Stop", updatedAt: Date())
        let store = try await makeStore(hook: question)
        let session = try XCTUnwrap(store.sessions["intune"])
        XCTAssertEqual(session.record?.event, "Stop", "the hook's question is what the row reads")
        XCTAssertTrue(session.isAlive, "the daemon still lists the session, so it is running")
        XCTAssertEqual(store.displayedExport().rows.map(\.laneID), ["intune"], "so Open keeps its row")
        store.detachAll()
    }

    func testASessionTheDaemonNoLongerListsIsNotAliveForAHooksRecord() async throws {
        let store = try await makeStore(hook: nil)
        let session = try XCTUnwrap(store.sessions["intune"])
        XCTAssertTrue(session.isAlive)
        session.update(record: LaneStatus(agent: "claude", state: .waitingForInput, lane: "intune", sessionID: full, event: "Stop"),
                       polled: nil)
        XCTAssertFalse(session.isAlive, "a hook's record alone does not say the session runs")
        store.detachAll()
    }
}
