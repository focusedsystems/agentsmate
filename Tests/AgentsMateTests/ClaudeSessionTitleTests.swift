import XCTest
@testable import AgentsMate
@testable import AgentsMateStatus

final class ClaudeSessionTitleTests: XCTestCase {
    private var home: URL!
    private let id = "529cddf5-ef48-4dc9-a4c5-a400b0bd8adb"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func write(_ project: String, _ lines: [String]) throws -> URL {
        let dir = home.appendingPathComponent("projects/\(project)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func rename(_ title: String) -> String {
        Fixture.line(["type": "agent-name", "agentName": title, "sessionId": id])
    }

    private var record: LaneStatus {
        LaneStatus(agent: "claude", state: .running, directory: "/work/My Repo.v2", sessionID: id, event: ClaudeAgentsList.event, agentID: "529cddf5")
    }

    func testABackgroundRecordWithNoFileIsFoundByItsSessionId() {
        XCTAssertEqual(LaneTranscriptCache.Source(record), .claudeSession(id: id, directory: "/work/My Repo.v2"))
    }

    func testTheFileIsFoundInTheFoldersProjectDirectory() throws {
        let url = try write("-work-My-Repo-v2", [Fixture.prompt("hi"), rename("Release review")])
        XCTAssertEqual(LaneTranscriptCache.claudeSessionFile(id: id, directory: "/work/My Repo.v2", environment: ["CLAUDE_CONFIG_DIR": home.path]), url.path)
    }

    func testAMovedSessionIsFoundByScanningTheProjects() throws {
        let url = try write("-somewhere-else", [rename("Moved")])
        XCTAssertEqual(LaneTranscriptCache.claudeSessionFile(id: id, directory: "/work/My Repo.v2", environment: ["CLAUDE_CONFIG_DIR": home.path]), url.path)
        XCTAssertNil(LaneTranscriptCache.claudeSessionFile(id: "not-an-id", directory: nil, environment: ["CLAUDE_CONFIG_DIR": home.path]))
    }

    func testTheTitleFollowsARenameAndTheLookupIsCached() throws {
        var cache = LaneTranscriptCache()
        cache.environment = ["CLAUDE_CONFIG_DIR": home.path]
        let source = try XCTUnwrap(LaneTranscriptCache.Source(record))
        let now = Date()
        _ = cache.read([source], now: now)
        XCTAssertNil(cache.title(source: source, record: record), "no file yet")
        let url = try write("-work-My-Repo-v2", [Fixture.prompt("hi"), rename("First")])
        _ = cache.read([source], now: now.addingTimeInterval(1))
        XCTAssertNil(cache.path(for: source), "a miss waits before looking again")
        _ = cache.read([source], now: now.addingTimeInterval(LaneTranscriptCache.codexRetry + 1))
        XCTAssertEqual(cache.path(for: source), url.path)
        XCTAssertEqual(cache.title(source: source, record: record), "First")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((rename("Second") + "\n").utf8))
        try handle.close()
        _ = cache.read([source], now: now.addingTimeInterval(200))
        XCTAssertEqual(cache.title(source: source, record: record), "Second")
        XCTAssertEqual(cache.claudeFiles[id], url.path, "found once, kept")
    }
}
