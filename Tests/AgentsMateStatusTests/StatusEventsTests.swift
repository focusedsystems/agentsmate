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
        XCTAssertNil(claude(#"{"hook_event_name":"Notification","notification_type":"idle_prompt"}"#))
        XCTAssertEqual(claude(#"{"hook_event_name":"Notification","notification_type":"elicitation_dialog"}"#)?.state, .waitingForInput)
        XCTAssertNil(claude(#"{"hook_event_name":"Notification","notification_type":"auth_success"}"#))
        XCTAssertEqual(claude(#"{"hook_event_name":"Notification","message":"Claude needs your permission to use Edit"}"#)?.state, .permissionRequested)
        XCTAssertNil(claude(#"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#))
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

final class LaneStatusPickTests: XCTestCase {
    func testPollsAndEventsCombine() {
        let permission = LaneStatus(agent: "claude", state: .permissionRequested, lane: "a", directory: "/w", event: "Notification",
                                    updatedAt: Date(timeIntervalSinceNow: -120))
        let idle = LaneStatus(agent: "claude", state: .done, lane: "A · Title", directory: "/w", event: ClaudeAgentsList.event)
        let busy = LaneStatus(agent: "claude", state: .running, lane: "A · Title", directory: "/w", event: ClaudeAgentsList.event)
        let match = LaneStatusMatch.directory("/w", agent: "claude")
        XCTAssertEqual(match.find(in: [permission, idle])?.state, .permissionRequested)
        XCTAssertEqual(match.find(in: [permission, busy])?.state, .running)
        XCTAssertEqual(match.find(in: [idle])?.state, .done)
    }
}

final class TurnEndTests: XCTestCase {
    private func stop(_ fields: [String: Any], transcript: LaneTranscript? = nil) -> LaneStatus? {
        var object = fields
        object["hook_event_name"] = "Stop"
        let data = try! JSONSerialization.data(withJSONObject: object)
        return StatusEvents.claude(hookInput: data, lane: "l", transcript: { _ in transcript })
    }

    func testStopOnAQuestionWaitsForThePerson() {
        let status = stop(["last_assistant_message": "Tests pass.\n\nShould I merge it?", "background_tasks": []])
        XCTAssertEqual(status?.state, .waitingForInput)
        XCTAssertEqual(status?.message, "Should I merge it?")
    }

    func testStopWithABackgroundShellStaysRunning() {
        let tasks: [[String: Any]] = [["id": "b1", "type": "shell", "status": "running", "description": "Run tests"]]
        XCTAssertEqual(stop(["last_assistant_message": "Started the tests.", "background_tasks": tasks])?.state, .running)
        // Other kinds of background work, and finished shells, do not count.
        let others: [[String: Any]] = [["id": "m1", "type": "monitor", "status": "running", "description": "watch"],
                                       ["id": "b2", "type": "shell", "status": "completed", "description": "x"]]
        XCTAssertEqual(stop(["last_assistant_message": "Watching.", "background_tasks": others])?.state, .done)
    }

    func testAQuestionWinsOverAnOpenShell() {
        let tasks: [[String: Any]] = [["id": "b1", "type": "shell", "status": "running", "description": "x"]]
        XCTAssertEqual(stop(["last_assistant_message": "Which branch?", "background_tasks": tasks])?.state, .waitingForInput)
    }

    func testStopOtherwiseIsDone() {
        let status = stop(["last_assistant_message": "All done.", "background_tasks": []])
        XCTAssertEqual(status?.state, .done)
        XCTAssertNil(status?.message)
        XCTAssertEqual(stop([:])?.state, .done)
    }

    func testOlderHooksFallBackToTheTranscript() {
        let asking = Fixture.read([Fixture.prompt("Ship it"), Fixture.reply("Ready. Merge now?")])
        XCTAssertEqual(stop(["transcript_path": "/t.jsonl"], transcript: asking)?.message, "Merge now?")
        let shell = Fixture.read([Fixture.backgroundBash("u1"), Fixture.backgroundStarted("u1", task: "b1"), Fixture.reply("Running in the background.")])
        XCTAssertEqual(stop(["transcript_path": "/t.jsonl"], transcript: shell)?.state, .running)
        let finished = Fixture.read([Fixture.backgroundBash("u1"), Fixture.backgroundStarted("u1", task: "b1"),
                                     Fixture.notification(task: "b1", useID: "u1"), Fixture.reply("Tests passed.")])
        XCTAssertEqual(stop(["transcript_path": "/t.jsonl"], transcript: finished)?.state, .done)
    }

    func testTheTranscriptIsReadOnlyWhenTheHookLeavesSomethingOut() {
        var reads = 0
        let data = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "transcript_path": "/t.jsonl",
                                                                "last_assistant_message": "Done.", "background_tasks": []])
        _ = StatusEvents.claude(hookInput: data, lane: nil, transcript: { _ in reads += 1; return nil })
        XCTAssertEqual(reads, 0)
        _ = StatusEvents.claude(hookInput: Data(#"{"hook_event_name":"PostToolUse","transcript_path":"/t.jsonl"}"#.utf8), lane: nil,
                                transcript: { _ in reads += 1; return nil })
        XCTAssertEqual(reads, 0)
    }

    func testIdleReminderLeavesTheStateAlone() {
        XCTAssertNil(StatusEvents.claude(hookInput: Data(#"{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#.utf8), lane: "l"))
        XCTAssertNil(StatusEvents.claude(hookInput: Data(#"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#.utf8), lane: "l"))
    }

    func testCodexTurnEndingOnAQuestion() {
        let asking = StatusEvents.codex(notifyPayload: Data(#"{"type":"agent-turn-complete","thread-id":"t1","last-assistant-message":"Built it.\nShall I push?"}"#.utf8), lane: "cx")
        XCTAssertEqual(asking?.state, .waitingForInput)
        XCTAssertEqual(asking?.message, "Shall I push?")
        XCTAssertEqual(asking?.sessionID, "t1")
        let done = StatusEvents.codex(notifyPayload: Data(#"{"type":"agent-turn-complete","last-assistant-message":"Pushed."}"#.utf8), lane: "cx")
        XCTAssertEqual(done?.state, .done)
    }
}
