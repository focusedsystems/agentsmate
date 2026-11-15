import XCTest
@testable import AgentsMateStatus

final class UsageTests: XCTestCase {
    func testCodexRateLimits() {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1800000000},"secondary":{"used_percent":12,"window_minutes":10080,"resets_in_seconds":3600}}}}"#
        let usage = CodexSessionUsageSource.parse(line: line)
        XCTAssertEqual(usage?.windows.map(\.label), ["5h", "Week"])
        XCTAssertEqual(usage?.fullest?.percent, 42.5)
        XCTAssertEqual(usage?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        let reached = CodexSessionUsageSource.parse(line: #"{"rate_limits":{"primary":null,"rate_limit_reached_type":"credits_depleted"}}"#)
        XCTAssertEqual(reached?.note, "Credits Depleted")
        XCTAssertNil(CodexSessionUsageSource.parse(line: "{}"))
    }

    func testKeyValueFile() {
        let usage = KeyValueUsageFileSource.parse("UTILIZATION=7\nRESETS_AT=2026-11-16T02:34:50Z\nWEEKLY_UTILIZATION=53\nTIMESTAMP=1794778490\n", agent: "Claude")
        XCTAssertEqual(usage?.windows.map(\.percent), [7, 53])
        XCTAssertEqual(usage?.fullest?.label, "Week")
        XCTAssertNil(KeyValueUsageFileSource.parse("nothing", agent: "Claude"))
    }
}

final class LaneNoteTests: XCTestCase {
    func testNotesUpdateAndClear() throws {
        let dir = LaneStatusDirectory(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString)/lanes", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: dir.url.deletingLastPathComponent()) }
        try dir.updateNote(lane: "build", text: "Compiling \u{1b}[1m", progress: 0.4)
        try dir.updateNote(lane: "build", log: "step 1")
        for i in 0..<30 { try dir.updateNote(lane: "build", log: "line \(i)") }
        let note = try XCTUnwrap(dir.readNote(lane: "build"))
        XCTAssertEqual(note.text, "Compiling [1m")
        XCTAssertEqual(note.progress, 0.4)
        XCTAssertEqual(note.log.count, LaneNote.maxLog)
        XCTAssertEqual(note.log.last, "line 29")
        try dir.updateNote(lane: "build", progress: -1)
        XCTAssertNil(dir.readNote(lane: "build")?.progress)
        XCTAssertEqual(dir.readNotes().count, 1)
        try dir.updateNote(lane: "build", clear: true)
        XCTAssertNil(dir.readNote(lane: "build"))
    }
}
