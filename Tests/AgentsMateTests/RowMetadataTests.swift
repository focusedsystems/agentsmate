import XCTest
@testable import AgentsMate

final class RowMetadataTests: XCTestCase {
    func testHeadParsing() {
        XCTAssertEqual(LaneRowMetadataReader.parseHead("ref: refs/heads/feature/x\n"), "feature/x")
        XCTAssertEqual(LaneRowMetadataReader.parseHead("0123456789abcdef"), "0123456")
        XCTAssertNil(LaneRowMetadataReader.parseHead(""))
    }

    func testBranchFromRepositoryAndWorktreeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent("repo/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let sub = root.appendingPathComponent("repo/a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(LaneRowMetadataReader.branch(in: sub.path), "main")
        let wtGit = root.appendingPathComponent("repo/.git/worktrees/w")
        try FileManager.default.createDirectory(at: wtGit, withIntermediateDirectories: true)
        try "ref: refs/heads/topic\n".write(to: wtGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let wt = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(wtGit.path)\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LaneRowMetadataReader.branch(in: wt.path), "topic")
        XCTAssertNil(LaneRowMetadataReader.branch(in: "/"))
    }

    func testPortsAndPullRequestParsing() {
        XCTAssertEqual(LaneRowMetadataReader.parsePorts("p123\nf5\nn*:3000\nn127.0.0.1:8080\nn[::1]:3000\n"), [3000, 8080])
        let pr = LaneRowMetadataReader.parsePullRequest(#"{"number":12,"state":"OPEN","isDraft":true,"url":"https://example.com/pr/12"}"#)
        XCTAssertEqual(pr?.number, 12)
        XCTAssertEqual(pr?.state, .draft)
        XCTAssertEqual(LaneRowMetadataReader.parsePullRequest(#"{"number":3,"state":"MERGED","isDraft":false}"#)?.state, .merged)
        XCTAssertNil(LaneRowMetadataReader.parsePullRequest("no pull requests found"))
    }

    func testProcessTreeIncludesSelf() {
        XCTAssertTrue(LaneRowMetadataReader.processTree(getpid()).contains(getpid()))
    }
}
