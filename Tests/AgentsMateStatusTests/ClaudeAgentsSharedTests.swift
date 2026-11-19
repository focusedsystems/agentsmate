import XCTest
@testable import AgentsMateStatus

final class ClaudeAgentsSharedTests: XCTestCase {
    private var dir: URL!
    private var cache: URL { dir.appendingPathComponent("claude-agents.json") }
    private let list = Data(#"[{"kind":"background","name":"focus","state":"working","sessionId":"s1"}]"#.utf8)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testFirstReaderFetchesAndWritesTheCache() {
        var calls = 0
        let records = ClaudeAgentsList.shared(cache: cache) { calls += 1; return self.list }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(records.first?.lane, "focus")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    func testFreshCacheIsReadWithoutFetching() throws {
        try list.write(to: cache)
        var calls = 0
        let records = ClaudeAgentsList.shared(cache: cache) { calls += 1; return nil }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(records.first?.state, .running)
    }

    func testStaleCacheIsRefetched() throws {
        try list.write(to: cache)
        let old = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cache.path)
        var calls = 0
        _ = ClaudeAgentsList.shared(cache: cache, maxAge: 25) { calls += 1; return self.list }
        XCTAssertEqual(calls, 1)
    }

    func testFailedFetchKeepsTheOldCopy() throws {
        try list.write(to: cache)
        let old = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cache.path)
        let records = ClaudeAgentsList.shared(cache: cache) { nil }
        XCTAssertEqual(records.first?.lane, "focus")
        XCTAssertEqual(records.first?.updatedAt.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 1)
    }
}
