import XCTest
import AgentsMateStatus
@testable import AgentsMate

@MainActor
final class ResumeSessionTests: XCTestCase {
    private let full = "7bd28ac9-3f2a-4c1e-9b4d-1a2b3c4d5e6f"

    // MARK: The refusal

    func testTheRefusalNamesTheSession() {
        let text = "\"Create · LinkedIn Headline Review\" is running in the background (7bd28ac9). "
            + "Run claude attach 7bd28ac9 to open it, or claude stop 7bd28ac9 first to resume it here."
        XCTAssertEqual(BackgroundSessionRefusal.sessionID(in: text), "7bd28ac9")
    }

    func testALineWrappedInTheMiddleOfTheIDIsStillFound() {
        let rows = [
            "  \"Create · LinkedIn Headline Review\" is running in the background (7bd2",
            "8ac9). Run claude attach 7bd28",
            "ac9 to open it, or claude stop 7bd28ac9 first to resume it here.            ",
        ]
        XCTAssertEqual(BackgroundSessionRefusal.sessionID(in: rows), "7bd28ac9")
        let narrow = ["x is running in the backg", "round (7bd28ac9). Run clau", "de attach 7bd28ac9 to open it"]
        XCTAssertEqual(BackgroundSessionRefusal.sessionID(in: narrow), "7bd28ac9")
    }

    func testOtherTextIsNotARefusal() {
        XCTAssertNil(BackgroundSessionRefusal.sessionID(in: "claude attach 7bd28ac9"))
        XCTAssertNil(BackgroundSessionRefusal.sessionID(in: "is running in the background (7bd28ac9). Run claude attach deadbeef"))
        XCTAssertNil(BackgroundSessionRefusal.sessionID(in: "is running in the background (xyz). Run claude attach xyz"))
        XCTAssertNil(BackgroundSessionRefusal.sessionID(in: ""))
    }

    func testTheNewestRefusalOnTheScreenWins() {
        let text = "a is running in the background (aaaa1111). Run claude attach aaaa1111 to open it\n"
            + "b is running in the background (bbbb2222). Run claude attach bbbb2222 to open it"
        XCTAssertEqual(BackgroundSessionRefusal.sessionID(in: text), "bbbb2222")
    }

    // MARK: The list

    private func list() -> Data {
        Data("""
        [
         {"id":"7bd28ac9","sessionId":"\(full)","name":"Create · LinkedIn","cwd":"/work/create","kind":"background","state":"done","startedAt":2000000},
         {"id":"11112222","sessionId":"11112222-3f2a-4c1e-9b4d-1a2b3c4d5e6f","name":"Old","cwd":"/work/create/sub","kind":"background","state":"stopped","startedAt":3000000},
         {"id":"33334444","sessionId":"33334444-3f2a-4c1e-9b4d-1a2b3c4d5e6f","name":"Older","cwd":"/work/create","kind":"background","state":"stopped","startedAt":1000000},
         {"id":"55556666","sessionId":"55556666-3f2a-4c1e-9b4d-1a2b3c4d5e6f","name":"Elsewhere","cwd":"/work/createx","kind":"background","state":"working"},
         {"id":"77778888","sessionId":"77778888-3f2a-4c1e-9b4d-1a2b3c4d5e6f","name":"Other","cwd":"/work/other","kind":"background","state":"working"},
         {"pid":4,"sessionId":"99990000-3f2a-4c1e-9b4d-1a2b3c4d5e6f","name":"tty","cwd":"/work/create","kind":"interactive","status":"busy"}
        ]
        """.utf8)
    }

    func testTheFoldersSessionsAreListedRunningFirst() {
        let found = ResumableSessions.parse(list(), under: "/work/create")
        XCTAssertEqual(found.map(\.name), ["Create · LinkedIn", "Old", "Older"])
        XCTAssertEqual(found.map(\.isRunning), [true, false, false])
        XCTAssertEqual(found.first?.shortID, "7bd28ac9")
    }

    // MARK: Opening

    private func store(cache: URL, lanes: [AgentLane] = []) -> AgentLaneStore {
        var backend = ClaudeBackgroundLaneBackend(id: "claude-bg", displayName: "Claude (Background)")
        backend.agentsListCache = cache
        backend.discoversSessions = false
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, notifies: false,
                                                  findsDetachedSessions: false, sharedLanes: nil,
                                                  liveSnapshotFile: nil, opensActiveOnly: false, displayedExportFile: nil)
        config.defaultsPrefix = "resume.\(UUID().uuidString)."
        let store = AgentLaneStore(configuration: config, backends: [backend], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-resume-\(UUID().uuidString)")!)
        for lane in lanes { store.add(lane, focus: false, open: false) }
        return store
    }

    private func cacheFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude-agents.json")
        try list().write(to: url)
        return url
    }

    func testARunningSessionOpensInANewRowBesideTheLaneThatSawTheRefusal() throws {
        let origin = AgentLane(id: "origin", title: "Create", directory: URL(fileURLWithPath: "/work/create"),
                               backendID: "claude-bg", isClosable: true, section: "Personal")
        let store = store(cache: try cacheFile(), lanes: [origin])
        let id = try XCTUnwrap(store.openRunningSession("7bd28ac9", near: "origin"))
        let lane = try XCTUnwrap(store.lanes.first { $0.id == id })
        XCTAssertEqual(lane.agentSessionID, "7bd28ac9")
        XCTAssertEqual(lane.section, "Personal")
        XCTAssertEqual(store.lanes.count, 2)
        XCTAssertEqual(store.lanes.first { $0.id == "origin" }, origin, "the lane that saw it is left as it was")
        // The same session again selects its row.
        XCTAssertEqual(store.openRunningSession("7bd28ac9", near: "origin"), id)
        XCTAssertEqual(store.lanes.count, 2)
        XCTAssertEqual(store.selectedID, id)
        store.detachAll()
    }

    func testAStoppedSessionResumesWithBgResumeAndStopsNothing() throws {
        let lane = AgentLane(id: "new", title: "Old", directory: URL(fileURLWithPath: "/work/create"), backendID: "claude-bg")
        let choice = ResumableSession(id: "11112222-3f2a-4c1e-9b4d-1a2b3c4d5e6f", shortID: "11112222", name: "Old",
                                      directory: "/work/create/sub", isRunning: false, startedAt: nil)
        let backend = ClaudeBackgroundLaneBackend(id: "claude-bg")
        let here = AgentLaneStore.resumeLaunch(for: choice, lane: lane, host: nil, backend: backend,
                                               config: HostSessionsConfiguration())
        let line = try XCTUnwrap(here.arguments.last)
        XCTAssertTrue(line.contains("claude --bg --resume 11112222-3f2a-4c1e-9b4d-1a2b3c4d5e6f"), line)
        XCTAssertTrue(line.contains("exec claude attach"), line)
        XCTAssertFalse(line.contains("claude stop"), "nothing is stopped for the person")
        let there = AgentLaneStore.resumeLaunch(for: choice, lane: lane, host: "lane-host", backend: backend,
                                                config: HostSessionsConfiguration())
        let ssh = try XCTUnwrap(there.arguments.last)
        XCTAssertTrue(ssh.contains("/usr/bin/ssh") && ssh.contains("lane-host") && ssh.contains("--resume"), ssh)
        XCTAssertFalse(ssh.contains("claude stop"))
    }

    func testTheMenuOffersResumeSessionWhereAClaudeCanListTheFolder() {
        var state = LaneMenuState()
        XCTAssertFalse(LaneMenuPlan.commands(state).contains(.resumeSession))
        state.canResumeSession = true
        XCTAssertTrue(LaneMenuPlan.commands(state).contains(.resumeSession))
        XCTAssertEqual(LaneMenuCommand.resumeSession.title(for: state), "Resume Session…")
    }
}
