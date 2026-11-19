import XCTest
@testable import AgentsMateStatus

final class AgentSignInTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCodexNeedsAuthFile() throws {
        let env = ["CODEX_HOME": dir.path]
        XCTAssertFalse(AgentSignIn.codex(environment: env))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("auth.json"))
        XCTAssertTrue(AgentSignIn.codex(environment: env))
    }

    func testClaudeNeedsAccount() throws {
        let env = ["CLAUDE_CONFIG_DIR": dir.path]
        XCTAssertFalse(AgentSignIn.claude(environment: env))
        let file = dir.appendingPathComponent(".claude.json")
        try Data(#"{"numStartups": 3}"#.utf8).write(to: file)
        XCTAssertFalse(AgentSignIn.claude(environment: env))
        try Data(#"{"oauthAccount": {"accountUuid": "x"}}"#.utf8).write(to: file)
        XCTAssertTrue(AgentSignIn.claude(environment: env))
        XCTAssertTrue(AgentSignIn.claude(environment: ["CLAUDE_CONFIG_DIR": "/nonexistent", "ANTHROPIC_API_KEY": "k"]))
    }

    func testSignedOutSourceReadsNothing() throws {
        let file = dir.appendingPathComponent("usage")
        try Data("UTILIZATION=40\n".utf8).write(to: file)
        XCTAssertNotNil(KeyValueUsageFileSource(url: file, agent: "Claude").read())
        XCTAssertNil(KeyValueUsageFileSource(url: file, agent: "Claude", signedIn: { false }).read())
    }
}
