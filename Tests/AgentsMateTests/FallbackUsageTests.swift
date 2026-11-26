import XCTest
@testable import AgentsMate
@testable import AgentsMateStatus

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class FallbackUsageTests: XCTestCase {
    private static let now = Date()

    private func cache(age: Int, percent: Int) -> String {
        "UTILIZATION=\(percent)\nRESETS_AT=2027-06-01T00:00:00Z\nWEEKLY_UTILIZATION=\(percent)\nWEEKLY_RESETS_AT=2027-06-01T00:00:00Z\nTIMESTAMP=\(Int(Self.now.timeIntervalSince1970) - age)\n"
    }

    private func local(_ text: String?) throws -> KeyValueUsageFileSource {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return KeyValueUsageFileSource(url: url, agent: "Claude")
    }

    private func remote(_ text: String, counter: Counter = Counter()) -> KeyValueUsageCommandSource {
        let now = Self.now
        return KeyValueUsageCommandSource(agent: "Claude", command: ["/usr/bin/ssh", "host"], interval: 60, maxInterval: 3600,
                                          timeout: 5, maxAge: KeyValueUsageFileSource.defaultMaxAge,
                                          runner: { _, _ in counter.bump(); return text }, clock: { now })
    }

    func testFreshLocalReadingNeverTouchesTheRemote() throws {
        let reads = Counter()
        let source = FallbackUsageSource(primary: try local(cache(age: 60, percent: 40)),
                                         fallbacks: [remote(cache(age: 10, percent: 90), counter: reads)], clock: { Self.now })
        XCTAssertEqual(source.read()?.fullest?.percent, 40)
        XCTAssertEqual(reads.count, 0)
    }

    func testStaleLocalFallsBackToTheFreshestRemote() throws {
        let source = FallbackUsageSource(
            primary: try local(cache(age: 7 * 86400, percent: 84)),
            fallbacks: [remote(cache(age: 1800, percent: 55)), remote(cache(age: 30, percent: 87)),
                        remote(cache(age: 7200, percent: 10))],
            clock: { Self.now })
        let usage = try XCTUnwrap(source.read())
        XCTAssertEqual(usage.fullest?.percent, 87, "the newest of the remote readings, not the first")
        XCTAssertFalse(usage.isUnknown)
    }

    func testMissingLocalFileFallsBackToo() throws {
        let source = FallbackUsageSource(primary: try local(nil), fallbacks: [remote(cache(age: 30, percent: 22))],
                                         clock: { Self.now })
        XCTAssertEqual(source.read()?.fullest?.percent, 22)
    }

    func testBothStaleStaysUnknown() throws {
        let source = FallbackUsageSource(primary: try local(cache(age: 7 * 86400, percent: 84)),
                                         fallbacks: [remote(cache(age: 2 * 86400, percent: 50)), remote("")],
                                         clock: { Self.now })
        let usage = try XCTUnwrap(source.read())
        XCTAssertTrue(usage.isUnknown)
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertEqual(usage.agent, "Claude")
    }
}
