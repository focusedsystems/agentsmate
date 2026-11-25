import XCTest
@testable import AgentsMateStatus

final class SessionTitleTests: XCTestCase {
    func testALeadingRowNameAndSeparatorIsStripped() {
        XCTAssertEqual(SessionTitle.subtitle("Billing · Quarterly Review", rowName: "Billing"), "Quarterly Review")
        XCTAssertEqual(SessionTitle.subtitle("billing·Quarterly", rowName: "Billing"), "Quarterly")
        XCTAssertEqual(SessionTitle.subtitle("  Billing  ·  Review  ", rowName: " Billing "), "Review")
    }

    func testATitleThatDoesNotRepeatTheNameIsKept() {
        XCTAssertEqual(SessionTitle.subtitle("Quarterly Review", rowName: "Billing"), "Quarterly Review")
        XCTAssertEqual(SessionTitle.subtitle("Billing quarterly review", rowName: "Billing"), "Billing quarterly review")
        XCTAssertEqual(SessionTitle.subtitle("Systems · Review", rowName: "Billing"), "Systems · Review")
    }

    func testATitleThatAddsNothingIsDropped() {
        XCTAssertNil(SessionTitle.subtitle(nil, rowName: "Billing"))
        XCTAssertNil(SessionTitle.subtitle("  ", rowName: "Billing"))
        XCTAssertNil(SessionTitle.subtitle("Billing", rowName: "Billing"))
        XCTAssertNil(SessionTitle.subtitle("Billing · ", rowName: "Billing"))
    }

    func testClaudeRenamesAreReadFromTheTranscriptAndTheLastWins() {
        var transcript = LaneTranscript(path: "", window: nil)
        let lines = [
            Fixture.prompt("hello"),
            Fixture.line(["type": "agent-name", "agentName": "First name", "sessionId": "s"]),
            Fixture.line(["type": "custom-title", "customTitle": "Second name", "sessionId": "s"]),
        ].joined(separator: "\n") + "\n"
        transcript.consume(Data(lines.utf8))
        XCTAssertEqual(transcript.sessionTitle, "Second name")
    }

    func testATranscriptNeverRenamedHasNoTitle() {
        var transcript = LaneTranscript(path: "", window: nil)
        transcript.consume(Data((Fixture.prompt("hi") + "\n").utf8))
        XCTAssertNil(transcript.sessionTitle)
    }

    func testCodexNamesTakeTheLastLinePerThreadAndSkipEmptyOnes() {
        let text = [
            #"{"id":"a","thread_name":"Old","updated_at":"2026-01-01T00:00:00Z"}"#,
            #"{"id":"b","thread_name":"Other","updated_at":"2026-01-01T00:00:00Z"}"#,
            #"{"id":"a","thread_name":"Billing · Quarterly Review","updated_at":"2026-01-02T00:00:00Z"}"#,
            #"{"id":"b","thread_name":" ","updated_at":"2026-01-03T00:00:00Z"}"#,
            "not json",
        ].joined(separator: "\n")
        let names = SessionTitle.codexNames(parsing: Data(text.utf8))
        XCTAssertEqual(names, ["a": "Billing · Quarterly Review"])
    }

    func testCodexNamesDropTheCutFirstLineOfATail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = #"{"id":"a","thread_name":"Long long name here"}"# + "\n" + #"{"id":"b","thread_name":"B"}"# + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionTitle.codexNames(in: url, bytes: 30), ["b": "B"])
        XCTAssertEqual(SessionTitle.codexNames(in: url).count, 2)
    }

    func testTheDisplayedRowCarriesTheTitleAsSessionTitle() throws {
        let row = DisplayedExport.Row(title: "t", laneID: "l", backend: "tmux", state: .working, sessionTitle: "Review")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any]
        XCTAssertEqual(object?["session_title"] as? String, "Review")
        let old = try JSONDecoder().decode(DisplayedExport.Row.self, from: JSONEncoder().encode(DisplayedExport.Row(title: "t", laneID: "l", backend: "tmux", state: .working)))
        XCTAssertNil(old.sessionTitle)
    }
}
