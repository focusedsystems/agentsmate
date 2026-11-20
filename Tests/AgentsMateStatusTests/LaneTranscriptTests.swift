import XCTest
@testable import AgentsMateStatus

/// Synthetic records in the shapes Claude Code and Codex write, cut down to
/// the fields the reader looks at.
enum Fixture {
    static func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func prompt(_ text: String) -> String {
        line(["type": "user", "message": ["role": "user", "content": text]])
    }

    static func reply(_ text: String) -> String {
        line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    static func backgroundBash(_ useID: String, description: String = "Run the tests") -> String {
        line(["type": "assistant", "message": ["role": "assistant", "content": [[
            "type": "tool_use", "id": useID, "name": "Bash",
            "input": ["command": "swift test", "description": description, "run_in_background": true],
        ]]]])
    }

    static func foregroundBash(_ useID: String) -> String {
        line(["type": "assistant", "message": ["role": "assistant", "content": [[
            "type": "tool_use", "id": useID, "name": "Bash", "input": ["command": "ls"],
        ]]]])
    }

    static func backgroundStarted(_ useID: String, task: String) -> String {
        line(["type": "user",
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": useID,
                                                       "content": "Command running in background with ID: \(task). Output is being written to: /tmp/out"]]],
              "toolUseResult": ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": task]])
    }

    static func toolResult(_ useID: String, text: String = "ok", error: Bool = false) -> String {
        line(["type": "user",
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": useID, "content": text, "is_error": error]]]])
    }

    static func notice(task: String, useID: String, status: String) -> String {
        "<task-notification>\n<task-id>\(task)</task-id>\n<tool-use-id>\(useID)</tool-use-id>\n<output-file>/tmp/out</output-file>\n<status>\(status)</status>\n<summary>Background command finished</summary>\n</task-notification>"
    }

    static func notification(task: String, useID: String, status: String = "completed") -> String {
        line(["type": "user", "message": ["role": "user", "content": notice(task: task, useID: useID, status: status)],
              "origin": ["kind": "task-notification"]])
    }

    static func enqueued(task: String, useID: String, status: String = "completed") -> String {
        line(["type": "queue-operation", "operation": "enqueue", "content": notice(task: task, useID: useID, status: status)])
    }

    static func taskStop(_ useID: String, task: String) -> String {
        line(["type": "assistant", "message": ["role": "assistant", "content": [[
            "type": "tool_use", "id": useID, "name": "TaskStop", "input": ["task_id": task],
        ]]]])
    }

    static func killShell(_ useID: String, shell: String) -> String {
        line(["type": "assistant", "message": ["role": "assistant", "content": [[
            "type": "tool_use", "id": useID, "name": "KillShell", "input": ["shell_id": shell],
        ]]]])
    }

    static func codexEvent(_ payload: [String: Any]) -> String {
        line(["timestamp": "2026-01-01T00:00:00Z", "type": "event_msg", "payload": payload])
    }

    static func codexItem(_ payload: [String: Any]) -> String {
        line(["timestamp": "2026-01-01T00:00:00Z", "type": "response_item", "payload": payload])
    }

    static func read(_ lines: [String]) -> LaneTranscript {
        var transcript = LaneTranscript(path: "", window: nil)
        transcript.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        return transcript
    }
}

final class LaneTranscriptTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("agentsmate-transcript-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func append(_ text: String) throws {
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    // MARK: Prompts and replies

    func testPromptsAndLastReply() {
        let t = Fixture.read([
            Fixture.prompt("Fix the login bug"),
            Fixture.reply("Looking at it"),
            Fixture.toolResult("t1"),
            Fixture.prompt("<command-name>/clear</command-name>"),
            Fixture.line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "Caveat: injected"]]),
            Fixture.prompt("Also add a test"),
            Fixture.reply("Fixed and tested."),
            "not json",
        ])
        XCTAssertEqual(t.prompts, ["Fix the login bug", "Also add a test"])
        XCTAssertEqual(t.lastReply, "Fixed and tested.")
        XCTAssertTrue(t.replyIsLast)
        XCTAssertFalse(t.endsOnQuestion)
    }

    func testSidechainRecordsAreSkipped() {
        let t = Fixture.read([
            Fixture.reply("Main reply"),
            Fixture.line(["type": "assistant", "isSidechain": true,
                          "message": ["content": [["type": "text", "text": "Subagent text?"]]]]),
        ])
        XCTAssertEqual(t.lastReply, "Main reply")
    }

    func testEndsOnQuestionOnlyWhenTheReplyIsLast() {
        XCTAssertEqual(Fixture.read([Fixture.prompt("Ship it"), Fixture.reply("Tests pass. Should I merge it?")]).question,
                       "Should I merge it?")
        // A tool call after the question means the agent carried on.
        XCTAssertNil(Fixture.read([Fixture.reply("Should I look?"), Fixture.foregroundBash("t1")]).question)
        // So does a new prompt.
        XCTAssertNil(Fixture.read([Fixture.reply("Should I look?"), Fixture.prompt("yes")]).question)
    }

    // MARK: Background shells

    func testBackgroundShellOpensAndFinishesByNotification() {
        var t = Fixture.read([Fixture.backgroundBash("toolu_1"), Fixture.backgroundStarted("toolu_1", task: "b1")])
        XCTAssertEqual(t.openBackgroundTasks, [LaneTranscript.BackgroundTask(id: "b1", toolUseID: "toolu_1", description: "Run the tests")])
        t.consume(Data((Fixture.notification(task: "b1", useID: "toolu_1") + "\n").utf8))
        XCTAssertTrue(t.openBackgroundTasks.isEmpty)
    }

    func testQueuedNoticeFinishesTheShellBeforeTheTurnReadsIt() {
        let t = Fixture.read([Fixture.backgroundBash("toolu_1"), Fixture.backgroundStarted("toolu_1", task: "b1"),
                              Fixture.enqueued(task: "b1", useID: "toolu_1", status: "failed")])
        XCTAssertTrue(t.openBackgroundTasks.isEmpty)
    }

    func testAttachedNoticeAndStatusSnapshots() {
        let queued = Fixture.line(["type": "attachment", "attachment": [
            "type": "queued_command", "commandMode": "task-notification",
            "prompt": Fixture.notice(task: "b1", useID: "u1", status: "completed"),
        ]])
        func snapshot(_ id: String, _ status: String, type: String = "local_bash") -> String {
            Fixture.line(["type": "attachment", "attachment": [
                "type": "task_status", "taskId": id, "taskType": type, "status": status,
                "description": "Serve the site", "shell": ["kind": "bash", "toolUseId": "u-" + id],
            ]])
        }
        let t = Fixture.read([
            Fixture.backgroundBash("u1"), Fixture.backgroundStarted("u1", task: "b1"), queued,
            // A shell started before the part of the file that was read.
            snapshot("b2", "running"),
            snapshot("b3", "running"), snapshot("b3", "completed"),
            snapshot("a1", "running", type: "local_agent"),
        ])
        XCTAssertEqual(t.openBackgroundTasks, [LaneTranscript.BackgroundTask(id: "b2", toolUseID: "u-b2", description: "Serve the site")])
    }

    func testStoppedAndKilledShellsClose() {
        let t = Fixture.read([
            Fixture.backgroundBash("u1"), Fixture.backgroundStarted("u1", task: "b1"),
            Fixture.backgroundBash("u2"), Fixture.backgroundStarted("u2", task: "b2"),
            Fixture.backgroundBash("u3"), Fixture.backgroundStarted("u3", task: "b3"),
            Fixture.taskStop("u4", task: "b1"),
            Fixture.killShell("u5", shell: "b2"),
        ])
        XCTAssertEqual(t.openBackgroundTasks.map(\.id), ["b3"])
    }

    func testOlderResultTextGivesTheID() {
        let t = Fixture.read([
            Fixture.backgroundBash("u1"),
            Fixture.toolResult("u1", text: "Command running in background with ID: bash_1"),
        ])
        XCTAssertEqual(t.openBackgroundTasks.map(\.id), ["bash_1"])
    }

    func testOlderOutputReadThatSaysCompletedCloses() {
        let t = Fixture.read([
            Fixture.backgroundBash("u1"), Fixture.backgroundStarted("u1", task: "bash_1"),
            Fixture.line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "u2", "name": "BashOutput", "input": ["bash_id": "bash_1"]]]]]),
            Fixture.line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "u2", "content": "done"]]],
                          "toolUseResult": ["shellId": "bash_1", "status": "completed"]]),
        ])
        XCTAssertTrue(t.openBackgroundTasks.isEmpty)
    }

    func testFailedStartOrForegroundBashOpensNothing() {
        let t = Fixture.read([
            Fixture.backgroundBash("u1"), Fixture.toolResult("u1", text: "denied", error: true),
            Fixture.foregroundBash("u2"), Fixture.backgroundStarted("u2", task: "x"),
        ])
        XCTAssertTrue(t.openBackgroundTasks.isEmpty)
    }

    func testProgressNoticeWithoutStatusKeepsTheShellOpen() {
        let t = Fixture.read([
            Fixture.backgroundBash("u1"), Fixture.backgroundStarted("u1", task: "b1"),
            Fixture.prompt("<task-notification>\n<task-id>b1</task-id>\n<summary>New output</summary>\n</task-notification>"),
        ])
        XCTAssertEqual(t.openBackgroundTasks.map(\.id), ["b1"])
    }

    // MARK: Pull requests

    func testPullRequestLinksFromReplies() {
        let t = Fixture.read([
            Fixture.prompt("See https://github.com/acme/widgets/pull/9"),
            Fixture.reply("Opened https://github.com/acme/widgets/pull/12."),
            Fixture.reply("Still https://github.com/acme/widgets/pull/12, plus https://org.visualstudio.com/Proj/_git/repo/pullrequest/56"),
            Fixture.reply("Not a PR: https://github.com/acme/widgets/issues/3"),
        ])
        XCTAssertEqual(t.pullRequestLinks.map(\.absoluteString), [
            "https://github.com/acme/widgets/pull/12",
            "https://org.visualstudio.com/Proj/_git/repo/pullrequest/56",
        ])
    }

    // MARK: Codex

    func testCodexSession() {
        let t = Fixture.read([
            Fixture.line(["type": "session_meta", "payload": ["id": "thread-1", "cwd": "/w"]]),
            Fixture.codexItem(["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>injected</environment_context>"]]]),
            Fixture.codexEvent(["type": "task_started", "turn_id": "t1"]),
            Fixture.codexEvent(["type": "user_message", "message": "Rename the module"]),
            Fixture.codexEvent(["type": "item_completed", "item": ["type": "UserMessage", "content": [["type": "text", "text": "And update the docs"]]]]),
            Fixture.codexItem(["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "Looking."]]]),
            Fixture.codexItem(["type": "custom_tool_call", "name": "exec", "call_id": "c1", "input": "ls"]),
            Fixture.codexEvent(["type": "item_completed", "item": ["type": "AgentMessage", "phase": "final_answer",
                                                                   "content": [["type": "Text", "text": "Renamed. PR: https://github.com/acme/w/pull/3. Want me to merge it?"]]]]),
            Fixture.codexEvent(["type": "task_complete", "last_agent_message": "Renamed. PR: https://github.com/acme/w/pull/3. Want me to merge it?"]),
        ])
        XCTAssertEqual(t.prompts, ["Rename the module", "And update the docs"])
        XCTAssertEqual(t.question, "Want me to merge it?")
        XCTAssertEqual(t.pullRequestLinks.map(\.absoluteString), ["https://github.com/acme/w/pull/3"])
        XCTAssertTrue(t.openBackgroundTasks.isEmpty)
    }

    func testCodexSessionFileByThreadID() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentsmate-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/01/02", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let want = day.appendingPathComponent("rollout-2026-01-02T10-00-00-abc-123.jsonl")
        FileManager.default.createFile(atPath: want.path, contents: Data())
        FileManager.default.createFile(atPath: day.appendingPathComponent("rollout-2026-01-02T09-00-00-other.jsonl").path, contents: Data())
        let env = ["CODEX_HOME": home.path]
        XCTAssertEqual(LaneTranscript.codexSessionFile(threadID: "abc-123", environment: env)?.standardizedFileURL, want.standardizedFileURL)
        XCTAssertNil(LaneTranscript.codexSessionFile(threadID: "missing", environment: env))
        XCTAssertNil(LaneTranscript.codexSessionFile(threadID: "../x", environment: env))
    }

    // MARK: Incremental reads

    func testUpdateReadsOnlyWhatWasAppended() throws {
        try append(Fixture.prompt("First") + "\n" + Fixture.reply("One"))
        var t = LaneTranscript(path: file.path, window: nil)
        XCTAssertTrue(t.hasChanged())
        XCTAssertTrue(t.update())
        // The reply has no newline yet: it waits for the rest of its line.
        XCTAssertEqual(t.prompts, ["First"])
        XCTAssertNil(t.lastReply)
        XCTAssertFalse(t.hasChanged())
        let before = t.offset
        try append("\n" + Fixture.prompt("Second") + "\n")
        XCTAssertTrue(t.hasChanged())
        t.update()
        XCTAssertGreaterThan(t.offset, before)
        XCTAssertEqual(t.prompts, ["First", "Second"])
        XCTAssertEqual(t.lastReply, "One")
        // Nothing new: nothing changes.
        let same = t
        t.update()
        XCTAssertEqual(t, same)
    }

    func testWindowSkipsTheStartAndAPartialLine() throws {
        try append(Fixture.prompt(String(repeating: "x", count: 500)) + "\n" + Fixture.prompt("Recent") + "\n")
        var t = LaneTranscript(path: file.path, window: 100)
        t.update()
        XCTAssertEqual(t.prompts, ["Recent"])
        XCTAssertNil(LaneTranscript.tail(path: file.path + ".missing"))
    }

    func testReplacedFileStartsOver() throws {
        try append(Fixture.prompt("Old one, a long prompt") + "\n")
        var t = LaneTranscript(path: file.path, window: nil)
        t.update()
        try Data((Fixture.prompt("New") + "\n").utf8).write(to: file)
        t.update()
        XCTAssertEqual(t.prompts, ["New"])
    }

    func testDigestOnTopOfTheReader() throws {
        try append([Fixture.prompt("a"), Fixture.prompt("b"), Fixture.prompt("c"), Fixture.prompt("d"),
                    Fixture.reply("line one\nline two")].joined(separator: "\n") + "\n")
        let digest = TranscriptDigest.read(path: file.path)
        XCTAssertEqual(digest, TranscriptDigest(prompts: ["b", "c", "d"], lastReply: "line one line two"))
    }
}

final class FinalQuestionTests: XCTestCase {
    private func q(_ s: String) -> String? { LaneTranscript.finalQuestion(in: s) }

    func testQuestions() {
        XCTAssertEqual(q("Done. Should I open the PR?"), "Should I open the PR?")
        XCTAssertEqual(q("Should I open the PR?\n\n  "), "Should I open the PR?")
        XCTAssertEqual(q("Summary\n\n- Want me to merge it?"), "Want me to merge it?")
        XCTAssertEqual(q("All green. **Merge now?**"), "Merge now?")
        XCTAssertEqual(q("Two options. Which do you prefer (A or B)?"), "Which do you prefer (A or B)?")
        XCTAssertEqual(q("Here it is:\n```swift\nlet x = 1\n```\nDoes that look right?"), "Does that look right?")
        XCTAssertEqual(q("Ready? Shall I go ahead?"), "Shall I go ahead?")
        XCTAssertEqual(q("要合并吗？"), "要合并吗？")
    }

    func testNotQuestions() {
        XCTAssertNil(q("Done."))
        XCTAssertNil(q(""))
        XCTAssertNil(q("Should I? No, it is done."))
        // A question inside a code block, even an unclosed one, is code.
        XCTAssertNil(q("Run this:\n```\nread -p \"Continue?\"\n```"))
        XCTAssertNil(q("Here:\n```sh\necho ok?"))
        XCTAssertNil(q("Here:\n\n    if ready?"))
        XCTAssertNil(q("Then run `test?`"))
        XCTAssertNil(q("You asked:\n> can it be faster?"))
        XCTAssertNil(q("| col | ok? |"))
        XCTAssertNil(q("## Open questions?"))
        XCTAssertNil(q("See https://example.com/search?"))
        XCTAssertNil(q("???"))
        XCTAssertNil(q("Ready to merge? (y/n)"))
    }
}
