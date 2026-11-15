import XCTest
@testable import AgentsMateStatus

final class StatusEventsTests: XCTestCase {
    private func claude(_ json: String, lane: String? = "focus") -> LaneStatus? {
        StatusEvents.claude(hookInput: Data(json.utf8), lane: lane)
    }

    func testClaudeEventsMapToStates() {
        XCTAssertEqual(claude(#"{"hook_event_name":"UserPromptSubmit","cwd":"/w","session_id":"s"}"#)?.state, .running)
        XCTAssertEqual(claude(#"{"hook_event_name":"PostToolUse"}"#)?.state, .running)
        XCTAssertEqual(claude(#"{"hook_event_name":"Stop"}"#)?.state, .done)
        XCTAssertEqual(claude(#"{"hook_event_name":"SessionStart"}"#)?.state, .waitingForInput)
        XCTAssertEqual(claude(#"{"hook_event_name":"SessionEnd"}"#)?.state, .ended)
        XCTAssertEqual(claude(#"{"hook_event_name":"PermissionRequest"}"#)?.state, .permissionRequested)
        XCTAssertNil(claude(#"{"hook_event_name":"SubagentStop"}"#))
        XCTAssertNil(claude("not json"))
    }

    func testClaudeNotificationTypes() {
        let permission = claude(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#)
        XCTAssertEqual(permission?.state, .permissionRequested)
        XCTAssertEqual(permission?.message, "Claude needs your permission to use Bash")
        XCTAssertEqual(claude(#"{"hook_event_name":"Notification","notification_type":"idle_prompt"}"#)?.state, .waitingForInput)
        XCTAssertNil(claude(#"{"hook_event_name":"Notification","notification_type":"auth_success"}"#))
        XCTAssertEqual(claude(#"{"hook_event_name":"Notification","message":"Claude needs your permission to use Edit"}"#)?.state, .permissionRequested)
        XCTAssertEqual(claude(#"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#)?.state, .waitingForInput)
    }

    func testClaudeRecordCarriesLaneAndFolder() throws {
        let status = try XCTUnwrap(claude(#"{"hook_event_name":"Stop","cwd":"/work/a","session_id":"abc"}"#))
        XCTAssertEqual(status.agent, "claude")
        XCTAssertEqual(status.lane, "focus")
        XCTAssertEqual(status.directory, "/work/a")
        XCTAssertEqual(status.sessionID, "abc")
        XCTAssertEqual(status.key, "claude--focus")
    }

    func testCodexNotify() {
        let done = StatusEvents.codex(notifyPayload: Data(#"{"type":"agent-turn-complete","thread-id":"t1","cwd":"/w","last-assistant-message":"All set.\nBye"}"#.utf8), lane: "cx-w")
        XCTAssertEqual(done?.state, .done)
        XCTAssertEqual(done?.sessionID, "t1")
        XCTAssertEqual(done?.message, "All set. Bye")
        XCTAssertEqual(StatusEvents.codex(notifyPayload: Data(#"{"type":"approval-requested"}"#.utf8), lane: nil)?.state, .permissionRequested)
        XCTAssertNil(StatusEvents.codex(notifyPayload: Data(#"{"type":"something-new"}"#.utf8), lane: nil))
    }

    func testKeysAreSafeFileNames() {
        let status = LaneStatus(agent: "claude", state: .done, lane: "../a b/c", event: "Stop")
        XCTAssertFalse(status.key.contains("/"))
        XCTAssertFalse(status.key.hasPrefix("."))
    }
}

final class LaneStatusDirectoryTests: XCTestCase {
    private var dir: LaneStatusDirectory!

    override func setUp() {
        dir = LaneStatusDirectory(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsmate-tests-\(UUID().uuidString)", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.url)
    }

    func testWriteReplacesTheLaneRecord() throws {
        try dir.write(LaneStatus(agent: "claude", state: .running, lane: "a", event: "UserPromptSubmit"))
        try dir.write(LaneStatus(agent: "claude", state: .done, lane: "a", event: "Stop"))
        let all = dir.readAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.state, .done)
    }

    func testEndedSessionOutsideALaneLeavesNothing() throws {
        try dir.write(LaneStatus(agent: "claude", state: .running, sessionID: "x", event: "UserPromptSubmit"))
        try dir.write(LaneStatus(agent: "claude", state: .ended, sessionID: "x", event: "SessionEnd"))
        XCTAssertTrue(dir.readAll().isEmpty)
    }

    func testStaleRecordsAreDropped() throws {
        try dir.write(LaneStatus(agent: "claude", state: .done, lane: "old", event: "Stop",
                                 updatedAt: Date(timeIntervalSinceNow: -30 * 24 * 3600)))
        XCTAssertTrue(dir.readAll().isEmpty)
    }

    func testDefaultHonoursOverrides() {
        XCTAssertEqual(LaneStatusDirectory.default(environment: ["AGENTSMATE_STATUS_DIR": "/tmp/x"]).url.path, "/tmp/x")
        XCTAssertEqual(LaneStatusDirectory.default(environment: ["XDG_STATE_HOME": "/s"]).url.path, "/s/agentsmate/lanes")
    }
}

final class LaneStatusMatchTests: XCTestCase {
    func testDirectoryMatchIgnoresRecordsOutsideLanes() {
        let records = [
            LaneStatus(agent: "claude", state: .running, lane: nil, directory: "/w/a", event: "UserPromptSubmit", updatedAt: Date()),
            LaneStatus(agent: "claude", state: .done, lane: "a", directory: "/w/a/", event: "Stop", updatedAt: Date(timeIntervalSinceNow: -60)),
            LaneStatus(agent: "codex", state: .running, lane: "cx-a", directory: "/w/a", event: "x", updatedAt: Date()),
        ]
        XCTAssertEqual(LaneStatusMatch.directory("/w/a", agent: "claude").find(in: records)?.state, .done)
        XCTAssertEqual(LaneStatusMatch.directory("/w/a", agent: nil).find(in: records)?.agent, "codex")
        XCTAssertEqual(LaneStatusMatch.lane("cx-a").find(in: records)?.agent, "codex")
        XCTAssertNil(LaneStatusMatch.none.find(in: records))
    }
}

final class ClaudeAgentsListTests: XCTestCase {
    private let json = #"""
    [{"id":"73f6db7c","cwd":"/w/a","kind":"background","sessionId":"73f6db7c-1","name":"a","state":"blocked"},
     {"id":"1","cwd":"/w/b","kind":"background","name":"b","state":"working"},
     {"pid":1,"cwd":"/w/c","kind":"interactive","sessionId":"s","name":"C · Title","status":"busy"}]
    """#

    func testBackgroundSessionsOnlyByDefault() {
        let records = ClaudeAgentsList.parse(Data(json.utf8))
        XCTAssertEqual(records.map(\.lane), ["a", "b"])
        XCTAssertEqual(records.map(\.state), [.waitingForInput, .running])
        XCTAssertEqual(ClaudeAgentsList.parse(Data(json.utf8), includeInteractive: true).last?.state, .running)
        XCTAssertTrue(ClaudeAgentsList.parse(Data("nope".utf8)).isEmpty)
    }
}

final class SessionMatchTests: XCTestCase {
    func testMatchesBySessionIDOrItsStart() {
        let records = [
            LaneStatus(agent: "claude", state: .running, lane: "Renamed", directory: "/w", sessionID: "73f6db7c-1", event: "claude agents"),
            LaneStatus(agent: "claude", state: .done, lane: "Other", directory: "/w", sessionID: "aaaa", event: "claude agents"),
        ]
        XCTAssertEqual(LaneStatusMatch.session("73f6db7c").find(in: records)?.state, .running)
        XCTAssertNil(LaneStatusMatch.session("").find(in: records))
        XCTAssertEqual(LaneStatusMatch.firstOf([.session("zz"), .lane("Other")]).find(in: records)?.state, .done)
    }
}
