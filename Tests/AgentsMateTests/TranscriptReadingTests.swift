import XCTest
import AgentsMateStatus
@testable import AgentsMate

@MainActor
final class TranscriptReadingTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentsmate-lanes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testScheduleIsFasterWhileShowing() {
        XCTAssertEqual(TranscriptSchedule.interval(showing: true), 5)
        XCTAssertEqual(TranscriptSchedule.interval(showing: false), 30)
    }

    func testSourceComesFromTheRecord() {
        XCTAssertEqual(LaneTranscriptCache.Source(LaneStatus(agent: "claude", state: .done, event: "Stop", transcriptPath: "/t.jsonl")), .path("/t.jsonl"))
        XCTAssertEqual(LaneTranscriptCache.Source(LaneStatus(agent: "codex", state: .done, sessionID: "th", event: "agent-turn-complete")), .codexThread("th"))
        XCTAssertNil(LaneTranscriptCache.Source(LaneStatus(agent: "claude", state: .done, sessionID: "s", event: "Stop")))
        XCTAssertNil(LaneTranscriptCache.Source(nil))
    }

    func testOnlyChangedFilesAreReadAgain() throws {
        let file = folder.appendingPathComponent("s.jsonl")
        try append(line(["type": "user", "message": ["content": "First"]]), to: file)
        var cache = LaneTranscriptCache()
        let source = LaneTranscriptCache.Source.path(file.path)
        XCTAssertEqual(cache.read([source])[file.path]?.prompts, ["First"])
        XCTAssertTrue(cache.read([source]).isEmpty)
        try append(line(["type": "assistant", "message": ["content": [["type": "text", "text": "PR: https://github.com/a/b/pull/1"]]]]), to: file)
        XCTAssertEqual(cache.read([source])[file.path]?.pullRequestLinks.map(\.absoluteString), ["https://github.com/a/b/pull/1"])
        // A lane that no longer names the file lets its reader go.
        _ = cache.read([])
        XCTAssertTrue(cache.readers.isEmpty)
    }

    func testCodexThreadIsFoundOnceAndMissesWait() throws {
        var cache = LaneTranscriptCache()
        cache.environment = ["CODEX_HOME": folder.path]
        let now = Date()
        XCTAssertTrue(cache.read([.codexThread("th-1")], now: now).isEmpty)
        let day = folder.appendingPathComponent("sessions/2026/02/03", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try append(line(["type": "event_msg", "payload": ["type": "user_message", "message": "Hello"]]),
                   to: day.appendingPathComponent("rollout-2026-02-03T01-02-03-th-1.jsonl"))
        // Not looked for again straight after a miss.
        XCTAssertTrue(cache.read([.codexThread("th-1")], now: now.addingTimeInterval(1)).isEmpty)
        let found = cache.read([.codexThread("th-1")], now: now.addingTimeInterval(LaneTranscriptCache.codexRetry + 1))
        XCTAssertEqual(found.values.first?.prompts, ["Hello"])
        XCTAssertNotNil(cache.path(for: .codexThread("th-1")))
    }

    func testSessionTakesTheTranscript() throws {
        let session = AgentLaneSession(lane: AgentLane(id: "a", title: "A", backendID: "x"), backend: CommandLaneBackend(id: "x", displayName: "X", command: "true"))
        var transcript = LaneTranscript(path: "", window: nil)
        transcript.consume(Data((line(["type": "user", "message": ["content": "Do it"]])
            + line(["type": "assistant", "message": ["content": [["type": "text", "text": "Done."]]]])).utf8))
        session.update(transcript: transcript)
        XCTAssertEqual(session.recentPrompts, ["Do it"])
        XCTAssertEqual(session.lastReply, "Done.")
    }

    func testPresenceOrASessionListMakesALaneActive() {
        let session = AgentLaneSession(lane: AgentLane(id: "a", title: "A", backendID: "x"), backend: CommandLaneBackend(id: "x", displayName: "X", command: "true"))
        XCTAssertFalse(session.isActive)
        session.update(present: true)
        XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.isAttached)
        session.update(present: false)
        session.update(record: LaneStatus(agent: "claude", state: .running, lane: "a", event: ClaudeAgentsList.event))
        XCTAssertTrue(session.isActive)
        session.update(record: LaneStatus(agent: "claude", state: .done, lane: "a", event: "Stop"))
        XCTAssertFalse(session.isActive)
    }
}
