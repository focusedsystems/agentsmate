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
