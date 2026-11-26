import XCTest
@testable import AgentsMateStatus

final class AgentBoardTests: XCTestCase {
    private func export(_ bundle: String, rows: [DisplayedExport.Row]) -> DisplayedExport {
        DisplayedExport(app: .init(bundleID: bundle), rows: rows, allAgents: rows)
    }

    func testOneCardPerSessionPreferringTheLocalOwnerCopy() {
        let row = DisplayedExport.Row(title: "Setup", laneID: "a:1", backend: "claude-bg", sessionID: "abc123",
                                      host: "hub", state: .needsYou, column: "needs_you", ownerApp: "app.one")
        var other = row
        other.laneID = "b:1"
        other.ownerApp = "app.one"
        let hub = AgentBoard.HostSnapshot(host: "hub", exports: [export("app.one", rows: [row]), export("app.two", rows: [other])],
                                          runningApps: ["app.one", "app.two"])
        let laptop = AgentBoard.HostSnapshot(host: "laptop", exports: [export("app.one", rows: [row])],
                                             runningApps: ["app.one"])
        let cards = AgentBoard.cards(from: [hub, laptop], localHost: "laptop")
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].seenOn, "laptop")
        XCTAssertEqual(cards[0].app, "app.one")
        XCTAssertEqual(cards[0].column, .needsYou)
    }

    func testExportsOfClosedAppsAreIgnored() {
        let row = DisplayedExport.Row(title: "Old", laneID: "x", backend: "tmux", sessionName: "old", state: .working)
        let snap = AgentBoard.HostSnapshot(host: "hub", exports: [export("app.gone", rows: [row])], runningApps: [])
        XCTAssertTrue(AgentBoard.cards(from: [snap], localHost: "hub").isEmpty)
    }

    func testUnlistedBackgroundSessionsGetTheirOwnCard() {
        let record = LaneStatus(agent: "claude", state: .running, lane: "Loose", directory: "/tmp",
                                sessionID: "11111111-2222-3333-4444-555555555555", message: ClaudeAgentsList.backgroundMessage,
                                event: ClaudeAgentsList.event, updatedAt: Date(), agentID: "loose1")
        let snap = AgentBoard.HostSnapshot(host: "hub", claudeSessions: [record], runningApps: [])
        let cards = AgentBoard.cards(from: [snap], localHost: "hub")
        XCTAssertEqual(cards.count, 1)
        XCTAssertNil(cards[0].app)
        XCTAssertEqual(cards[0].column, .working)
        XCTAssertEqual(cards[0].sessionID, "loose1")
    }

    func testParseNeedsTheEndMarkAndReadsSections() throws {
        let marks = AgentBoard.Marks(nonce: "n")
        let data = try export("app.one", rows: []).encoded()
        let summaries = #"{"K":{"summary":"Doing the thing","generatedAt":"2026-11-25T10:00:00Z","source":"/x/abcdefab-1234-1234-1234-abcdefabcdef.jsonl"}}"#
        let body = [marks.export, String(decoding: data, as: UTF8.self), marks.summariesPrefix, summaries,
                    marks.agents, "[]", marks.apps, "app.one", ""].joined(separator: "\n")
        XCTAssertNil(AgentBoard.parse(body, host: "hub", marks: marks))
        let snap = try XCTUnwrap(AgentBoard.parse(body + marks.end + "\n", host: "hub", marks: marks))
        XCTAssertEqual(snap.exports.count, 1)
        XCTAssertEqual(snap.runningApps, ["app.one"])
        XCTAssertEqual(snap.summaries["abcdefab-1234-1234-1234-abcdefabcdef"]?.text, "Doing the thing")
    }

    func testStopScriptsRefuseUnsafeNames() {
        XCTAssertNil(AgentSessionStop.script(for: .claudeBackground(id: "-rf")))
        XCTAssertNil(AgentSessionStop.script(for: .tmux(name: "a'b")))
        XCTAssertNil(AgentSessionStop.command(script: "true", host: "-oProxyCommand=x"))
        let claude = try? XCTUnwrap(AgentSessionStop.script(for: .claudeBackground(id: "abc123")))
        XCTAssertTrue(claude?.contains("'claude' stop 'abc123'") == true)
        let tmux = AgentSessionStop.script(for: .tmux(name: "lane-a")) ?? ""
        XCTAssertTrue(tmux.contains("-l /exit"))
        XCTAssertTrue(tmux.contains("kill-session -t '=lane-a'"))
    }

    func testLaneRequestRoundTripsAndExpires() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let env = ["XDG_STATE_HOME": dir.path]
        let request = LaneRequest(action: .show, app: "app.one", laneID: "a:1")
        XCTAssertTrue(request.send(environment: env))
        XCTAssertEqual(LaneRequest.take(bundleID: "app.one", environment: env)?.laneID, "a:1")
        XCTAssertNil(LaneRequest.take(bundleID: "app.one", environment: env))
        let old = LaneRequest(action: .close, app: "app.one", at: Date().addingTimeInterval(-600))
        XCTAssertTrue(old.send(environment: env))
        XCTAssertNil(LaneRequest.take(bundleID: "app.one", environment: env))
    }
}
