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
        XCTAssertEqual(reached?.isDepleted, true, "a reached limit with no window is depleted")
        XCTAssertNil(reached?.depletedUntil, "Codex gives no reset for spent credits")
        XCTAssertNil(CodexSessionUsageSource.parse(line: "{}"))
    }

    func testKeyValueFile() {
        let usage = KeyValueUsageFileSource.parse("UTILIZATION=7\nRESETS_AT=2026-11-16T02:34:50Z\nWEEKLY_UTILIZATION=53\nTIMESTAMP=1794778490\n", agent: "Claude")
        XCTAssertEqual(usage?.windows.map(\.percent), [7, 53])
        XCTAssertEqual(usage?.fullest?.label, "Week")
        XCTAssertNil(KeyValueUsageFileSource.parse("nothing", agent: "Claude"))
    }

    /// A Mac whose agents all run elsewhere: its status line last wrote the
    /// file days ago, and the session it describes has reset since.
    func testOldFileAfterItsResetIsUnknown() throws {
        let text = "UTILIZATION=84\nRESETS_AT=2026-11-19T13:00:00Z\nTIMESTAMP=1794985738\n"
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T18:00:00Z"))
        let usage = try XCTUnwrap(KeyValueUsageFileSource.usage(from: text, agent: "Claude", now: now, maxAge: nil))
        XCTAssertTrue(usage.windows.isEmpty, "the reset has passed, so 84% is not today's figure")
        XCTAssertTrue(usage.isUnknown)
        XCTAssertNil(usage.fullest)

        let fresh = "UTILIZATION=84\nRESETS_AT=2026-11-21T13:00:00Z\nTIMESTAMP=\(Int(now.timeIntervalSince1970) - 60)\n"
        XCTAssertEqual(KeyValueUsageFileSource.usage(from: fresh, agent: "Claude", now: now)?.fullest?.percent, 84)
    }

    func testFileOlderThanMaxAgeIsUnknown() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = { (age: Int) in "UTILIZATION=40\nRESETS_AT=2027-06-01T00:00:00Z\nWEEKLY_UTILIZATION=20\nTIMESTAMP=\(1_800_000_000 - age)\n" }
        XCTAssertEqual(KeyValueUsageFileSource.usage(from: text(600), agent: "Claude", now: now)?.windows.count, 2)
        let old = try XCTUnwrap(KeyValueUsageFileSource.usage(from: text(7200), agent: "Claude", now: now))
        XCTAssertTrue(old.isUnknown, "two hours old is past the default hour")
        XCTAssertEqual(KeyValueUsageFileSource.usage(from: text(7200), agent: "Claude", now: now, maxAge: nil)?.windows.count, 2)
    }

    func testCurrentKeepsWindowsThatHaveNotReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        let usage = AgentUsage(agent: "Claude", windows: [.init(label: "Session", percent: 90, resetsAt: now.addingTimeInterval(-1)),
                                                          .init(label: "Week", percent: 30, resetsAt: now.addingTimeInterval(3600)),
                                                          .init(label: "Day", percent: 10)],
                               note: "Note", readAt: now)
        let current = usage.current(at: now)
        XCTAssertEqual(current.windows.map(\.label), ["Week", "Day"])
        XCTAssertEqual(current.fullest?.percent, 30, "the spent session no longer leads")
        XCTAssertEqual(current.note, "Note")
        XCTAssertFalse(current.isUnknown)
        XCTAssertEqual(usage.current(at: now.addingTimeInterval(-10)), usage, "nothing has reset yet")
    }

    func testFileSourceReadsStaleFileAsUnknown() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try "UTILIZATION=84\nRESETS_AT=2020-01-01T00:00:00Z\nTIMESTAMP=1577800000\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(KeyValueUsageFileSource(url: url, agent: "Claude").read()?.isUnknown, true)
        XCTAssertNil(KeyValueUsageFileSource(url: url, agent: "Claude", signedIn: { false }).read())
    }

    func testSpentCodexCreditsBorrowTheLatestFutureReset() {
        let now = Date(timeIntervalSince1970: 1_795_400_000)
        let window = { (used: Int, resets: Int) in
            #"{"rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(used),"window_minutes":10080,"resets_at":\#(resets)},"secondary":null}}"#
        }
        let spent = #"{"rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"credits":{"has_credits":false},"rate_limit_reached_type":"workspace_member_credits_depleted"}}"#
        let older = window(40, 1_795_000_000) // reset already passed
        let newer = [window(81, 1_795_539_448), window(82, 1_795_539_457), spent].joined(separator: "\n")
        let usage = try? XCTUnwrap(CodexSessionUsageSource.usage(fromNewestFirst: [newer, older], now: now))
        XCTAssertEqual(usage?.note, "Workspace Member Credits Depleted")
        XCTAssertEqual(usage?.isDepleted, true)
        XCTAssertEqual(usage?.depletedUntil, Date(timeIntervalSince1970: 1_795_539_457), "the latest reset still to come")

        // An earlier file can give it when the newest has none.
        let fromOlder = CodexSessionUsageSource.usage(fromNewestFirst: [spent, window(82, 1_795_539_457)], now: now)
        XCTAssertEqual(fromOlder?.depletedUntil, Date(timeIntervalSince1970: 1_795_539_457))

        // Nothing in the future: the passed weekly reset rolls on a week.
        let rolled = CodexSessionUsageSource.usage(fromNewestFirst: [[older, spent].joined(separator: "\n")], now: now)
        XCTAssertEqual(rolled?.isDepleted, true)
        XCTAssertEqual(rolled?.depletedUntil, Date(timeIntervalSince1970: 1_795_000_000 + 604_800))
        // A borrowed reset that passes is dropped.
        XCTAssertNil(usage?.current(at: Date(timeIntervalSince1970: 1_795_600_000)).depletedUntil)

        // Not depleted: the newest record as it is, no borrowing.
        let fine = CodexSessionUsageSource.usage(fromNewestFirst: [window(82, 1_795_539_457)], now: now)
        XCTAssertEqual(fine?.isDepleted, false)
        XCTAssertNil(fine?.resetsAt)
    }

    func testSpentCodexCreditsAlwaysGetAReset() {
        let now = Date(timeIntervalSince1970: 1_795_400_000)
        let spent = #"{"rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"rate_limit_reached_type":"workspace_member_credits_depleted"}}"#
        let window = #"{"rate_limits":{"limit_id":"codex","primary":{"used_percent":82,"window_minutes":10080,"resets_at":1795539457}}}"#
        let live = Date(timeIntervalSince1970: 1_795_539_448)

        // Codex's own answer comes first.
        let authoritative = CodexSessionUsageSource.usage(fromNewestFirst: [[window, spent].joined(separator: "\n")], now: now,
                                                          authoritative: { live })
        XCTAssertEqual(authoritative?.depletedUntil, live)

        // A spend limit of the member's own carries its reset, and no other is asked.
        let own = #"{"rate_limits":{"primary":null,"individual_limit":{"resets_at":1795500000},"rate_limit_reached_type":"workspace_member_credits_depleted"}}"#
        let fromOwn = CodexSessionUsageSource.usage(fromNewestFirst: [own], now: now, authoritative: { XCTFail("asked"); return nil })
        XCTAssertEqual(fromOwn?.depletedUntil, Date(timeIntervalSince1970: 1_795_500_000))

        // A passed answer is not used; the records' future reset is.
        let stale = CodexSessionUsageSource.usage(fromNewestFirst: [[window, spent].joined(separator: "\n")], now: now,
                                                  authoritative: { Date(timeIntervalSince1970: 1_795_000_000) })
        XCTAssertEqual(stale?.depletedUntil, Date(timeIntervalSince1970: 1_795_539_457))

        // No window in the recent files: older ones give one, rolled forward weeks at a time.
        let old = #"{"rate_limits":{"primary":{"used_percent":10,"window_minutes":10080,"resets_at":1794000000}}}"#
        let fromOlder = CodexSessionUsageSource.usage(fromNewestFirst: [spent], now: now, older: { [old] })
        XCTAssertEqual(fromOlder?.depletedUntil, Date(timeIntervalSince1970: 1_794_000_000 + 3 * 604_800))
        XCTAssertGreaterThan(fromOlder?.current(at: now).depletedUntil ?? .distantPast, now)

        // Older files are not read when the recent ones give a window.
        _ = CodexSessionUsageSource.usage(fromNewestFirst: [[window, spent].joined(separator: "\n")], now: now,
                                          older: { XCTFail("read older"); return [] })
    }

    func testRolledResetLandsOnTheNextPeriod() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let week: TimeInterval = 604_800
        let windows = [AgentUsage.Window(label: "Week", percent: 100, resetsAt: reset, length: week)]
        XCTAssertEqual(CodexSessionUsageSource.nextReset(of: windows, after: reset), reset.addingTimeInterval(week))
        XCTAssertEqual(CodexSessionUsageSource.nextReset(of: windows, after: reset.addingTimeInterval(week + 1)),
                       reset.addingTimeInterval(2 * week))
        XCTAssertNil(CodexSessionUsageSource.nextReset(of: [.init(label: "Week", percent: 1, resetsAt: reset)],
                                                       after: reset.addingTimeInterval(1)), "no length, no roll")
    }

    func testCodexAccountLimitsReply() {
        let upsell = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1795539448},"individualLimit":null},"rateLimitUpsell":{"reset_at":1795539449}}}"#
        XCTAssertEqual(CodexLimitsReader.parse(upsell), Date(timeIntervalSince1970: 1_795_539_449))
        let spend = #"{"id":2,"result":{"rateLimits":{"primary":null,"individualLimit":{"resetsAt":1795500000}}}}"#
        XCTAssertEqual(CodexLimitsReader.parse(spend), Date(timeIntervalSince1970: 1_795_500_000))
        let full = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":40,"resetsAt":1795000000}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":100,"resetsAt":1795539448}}}}}"#
        XCTAssertEqual(CodexLimitsReader.parse(full), Date(timeIntervalSince1970: 1_795_539_448))
        XCTAssertNil(CodexLimitsReader.parse(#"{"id":1,"result":{"userAgent":"x"}}"#))
    }

    func testCodexLimitsReaderRunsAtMostOncePerInterval() {
        final class Count: @unchecked Sendable { var runs = 0 }
        let count = Count()
        let reader = CodexLimitsReader(interval: 600) {
            count.runs += 1
            return #"{"id":2,"result":{"rateLimits":{},"rateLimitUpsell":{"reset_at":1795539448}}}"#
        }
        let now = Date(timeIntervalSince1970: 1_795_400_000)
        XCTAssertEqual(reader.depletedUntil(now: now), Date(timeIntervalSince1970: 1_795_539_448))
        XCTAssertEqual(reader.depletedUntil(now: now.addingTimeInterval(60)), Date(timeIntervalSince1970: 1_795_539_448))
        XCTAssertEqual(count.runs, 1)
        XCTAssertNil(reader.depletedUntil(now: Date(timeIntervalSince1970: 1_795_600_000)), "a passed reset is not given")
        XCTAssertEqual(count.runs, 2)
    }

    func testDepletedWhenAWindowIsFullOrALimitIsReached() {
        let now = Date()
        let soon = now.addingTimeInterval(3600), later = now.addingTimeInterval(86_400)
        let full = AgentUsage(agent: "Claude", windows: [.init(label: "Session", percent: 100, resetsAt: soon),
                                                         .init(label: "Week", percent: 100, resetsAt: later)])
        XCTAssertTrue(full.isDepleted)
        XCTAssertEqual(full.depletedUntil, later, "work resumes once every full window has reset")
        let partly = AgentUsage(agent: "Claude", windows: [.init(label: "Session", percent: 100, resetsAt: soon),
                                                           .init(label: "Week", percent: 40, resetsAt: later)])
        XCTAssertEqual(partly.depletedUntil, soon)
        XCTAssertFalse(AgentUsage(agent: "Claude", windows: [.init(label: "Week", percent: 99)]).isDepleted)
        XCTAssertFalse(AgentUsage(agent: "Codex", windows: [], note: AgentUsage.unknownNote).isDepleted,
                       "unknown is not depleted")
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

final class TranscriptDigestTests: XCTestCase {
    func testDigestSkipsToolResultsAndKeepsLastReply() {
        let text = [
            #"{"type":"user","message":{"role":"user","content":"Fix the login bug"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at auth.swift"},{"type":"tool_use","name":"Read"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"file text"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Also add a test"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done: fixed and tested."}]}}"#,
            "not json",
        ].joined(separator: "\n")
        let digest = TranscriptDigest.parse(text)
        XCTAssertEqual(digest?.prompts, ["Fix the login bug", "Also add a test"])
        XCTAssertEqual(digest?.lastReply, "Done: fixed and tested.")
        XCTAssertNil(TranscriptDigest.parse("nothing"))
    }

    func testClaudeRecordCarriesTranscript() {
        let status = StatusEvents.claude(hookInput: Data(#"{"hook_event_name":"Stop","transcript_path":"/t.jsonl"}"#.utf8), lane: "x")
        XCTAssertEqual(status?.transcriptPath, "/t.jsonl")
    }
}
