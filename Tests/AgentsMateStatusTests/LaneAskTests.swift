import XCTest
@testable import AgentsMateStatus

final class LaneAskTests: XCTestCase {
    private let json = """
    {"question":"q","llm":true,"hosts_searched":["a"],"hosts_skipped":["b"],"results":[
      {"rank":1,"host":"a","agent":"claude","lane_id":"L1","app":"app.one","session_id":"11111111-2222-3333-4444-555555555555",
       "cwd":"/work/x","last_active":"2026-11-27T22:36:17Z","title":"Fix","why":"Because","evidence":"e","work_items":["TASK-1"]},
      {"rank":2,"host":"","agent":"codex"}]}
    """

    private func script(_ body: String) throws -> (dir: URL, env: [String: String]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lane-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("fake-ask")
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return (dir, ["PATH": dir.path, "HOME": dir.path])
    }

    func testParseReadsAnswersAndDropsRowsWithoutAHost() throws {
        let response = try XCTUnwrap(LaneAsk.parse(Data(json.utf8)))
        XCTAssertTrue(response.usedModel)
        XCTAssertEqual(response.hostsSkipped, ["b"])
        XCTAssertEqual(response.answers.count, 1)
        let a = response.answers[0]
        XCTAssertEqual(a.laneID, "L1")
        XCTAssertEqual(a.folder, "/work/x")
        XCTAssertNotNil(a.lastActive)
        XCTAssertEqual(a.workItems, ["TASK-1"])
        XCTAssertNil(LaneAsk.parse(Data("nope".utf8)))
    }

    func testCommandNamesAreBareFileNames() {
        XCTAssertTrue(LaneAsk.isValidCommandName("lane-find"))
        XCTAssertFalse(LaneAsk.isValidCommandName("../x"))
        XCTAssertFalse(LaneAsk.isValidCommandName("-x"))
        XCTAssertFalse(LaneAsk.isValidCommandName(""))
    }

    func testRunReadsTheCommandsJSON() async throws {
        let (dir, env) = try script("cat <<'EOF'\n\(json)\nEOF")
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await LaneAsk.run(question: "where", command: "fake-ask", environment: env)
        guard case .answers(let response) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(response.answers.first?.title, "Fix")
    }

    func testQuestionReachesTheCommandAsOneArgument() async throws {
        let (dir, env) = try script(#"printf '{"results":[{"host":"h","title":"%s"}]}' "$3""#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await LaneAsk.run(question: "-x a b", command: "fake-ask", environment: env)
        guard case .answers(let response) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(response.answers.first?.title, "-x a b")
    }

    func testExitOneIsNoMatchAndMissingCommandIsReported() async throws {
        let (dir, env) = try script("echo '{\"results\":[]}'; exit 1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let none = await LaneAsk.run(question: "x", command: "fake-ask", environment: env)
        guard case .noMatch = none else { return XCTFail("\(none)") }
        let missing = await LaneAsk.run(question: "x", command: "absent-ask", environment: env)
        XCTAssertEqual(missing, .missingCommand("absent-ask"))
    }

    func testFailureCarriesTheErrorText() async throws {
        let (dir, env) = try script("echo broken >&2; exit 2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await LaneAsk.run(question: "x", command: "fake-ask", environment: env)
        XCTAssertEqual(outcome, .failed("broken"))
    }

    func testCancellingEndsTheCommand() async throws {
        let (dir, env) = try script("sleep 30")
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date()
        let task = Task { await LaneAsk.run(question: "x", command: "fake-ask", environment: env) }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testResumeCommandChecksEverythingItQuotes() {
        var answer = LaneAsk.Answer(rank: 1, host: "hub", agent: "claude", laneID: nil, app: nil,
                                    sessionID: "11111111-2222-3333-4444-555555555555", folder: "/work/it's",
                                    lastActive: nil, title: nil, evidence: "", why: "", workItems: [])
        let local = LaneAsk.resumeCommand(for: answer, isLocal: true)
        XCTAssertTrue(local?.contains("claude --resume") == true)
        XCTAssertTrue(LaneAsk.resumeCommand(for: answer, isLocal: false)?.contains("/usr/bin/ssh -t -- 'hub'") == true)
        answer.sessionID = "x; rm -rf /"
        XCTAssertNil(LaneAsk.resumeCommand(for: answer, isLocal: true))
        answer.sessionID = "11111111-2222-3333-4444-555555555555"
        answer.folder = "relative"
        XCTAssertNil(LaneAsk.resumeCommand(for: answer, isLocal: true))
        answer.folder = "/ok"
        answer.host = "-oProxyCommand=x"
        XCTAssertNil(LaneAsk.resumeCommand(for: answer, isLocal: false))
        answer.agent = "other"
        XCTAssertNil(LaneAsk.resumeCommand(for: answer, isLocal: true))
    }

    func testAnswerMatchesTheCardThatAlreadyHoldsItsLane() {
        let row = DisplayedExport.Row(title: "Setup", laneID: "L1", backend: "tmux", sessionName: "s", host: "hub", state: .working,
                                      ownerApp: "app.one")
        let export = DisplayedExport(app: .init(bundleID: "app.one"), rows: [row], allAgents: [row])
        let cards = AgentBoard.cards(from: [AgentBoard.HostSnapshot(host: "hub", exports: [export], runningApps: ["app.one"])],
                                     localHost: "hub")
        let hit = LaneAsk.Answer(rank: 1, host: "hub", agent: "claude", laneID: "L1", app: "app.one", sessionID: nil, folder: nil,
                                 lastActive: nil, title: nil, evidence: "", why: "", workItems: [])
        XCTAssertEqual(LaneAsk.card(for: hit, in: cards)?.laneID, "L1")
        var miss = hit
        miss.laneID = "other"
        XCTAssertNil(LaneAsk.card(for: miss, in: cards))
    }
}
