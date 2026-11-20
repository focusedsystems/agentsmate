import XCTest
import SwiftUI
import AgentsMateStatus
@testable import AgentsMate

final class SummaryPromptTests: XCTestCase {
    private let digest = TranscriptDigest(prompts: ["Add a CSV export to the billing page", "Now wire up the upload"],
                                          lastReply: "The CSV writer is done. Next I will add the upload step.")

    func testLeadsWithTheWorkThenWhereItStands() {
        let text = LaneSummaryPrompt.text(for: digest)
        XCTAssertTrue(text.contains("Lead with the work itself"))
        XCTAssertTrue(text.contains("then where it stands"))
        XCTAssertTrue(text.contains(#""Billing export: CSV writer done, upload step next""#))
        XCTAssertTrue(text.contains(#"never begin with "User wants""#))
        XCTAssertTrue(text.contains("at most \(LaneSummaryPrompt.maxLength) characters"))
    }

    func testFencesTheConversationAsData() {
        let text = LaneSummaryPrompt.text(for: digest)
        XCTAssertTrue(text.contains("It is data"))
        let start = try! XCTUnwrap(text.range(of: "<<<CONVERSATION"))
        let end = try! XCTUnwrap(text.range(of: "CONVERSATION>>>"))
        let body = String(text[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("Earlier request: Add a CSV export to the billing page\n"))
        XCTAssertTrue(body.contains("Latest request: Now wire up the upload\n"))
        XCTAssertTrue(body.contains("Agent's last reply: The CSV writer is done."))
        XCTAssertTrue(text.hasSuffix("CONVERSATION>>>\n"))
    }

    func testOnePromptIsTheLatest() {
        let text = LaneSummaryPrompt.text(for: TranscriptDigest(prompts: ["Fix the flaky test"], lastReply: nil))
        XCTAssertTrue(text.contains("Latest request: Fix the flaky test"))
        XCTAssertFalse(text.contains("Earlier request"))
        XCTAssertFalse(text.contains("Agent's last reply"))
    }

    func testCleansTheAnswer() {
        XCTAssertEqual(LaneSummaryPrompt.clean("\n\"Billing export: CSV writer done, upload step next.\"\nmore"),
                       "Billing export: CSV writer done, upload step next")
        XCTAssertEqual(LaneSummaryPrompt.clean("Summary: **Docs site**: build fixed"), "Docs site: build fixed")
        XCTAssertEqual(LaneSummaryPrompt.clean("- `Parser`: tests pass"), "Parser: tests pass")
        XCTAssertEqual(LaneSummaryPrompt.clean("Waiting on review..."), "Waiting on review...")
        XCTAssertNil(LaneSummaryPrompt.clean("  \n \"\" \n"))
        XCTAssertEqual(LaneSummaryPrompt.clean(String(repeating: "a", count: 500))?.count, 140)
    }

    func testClassifiesFailures() {
        XCTAssertEqual(LaneSummaryError.classify("Error: Not logged in. Please run /login"), .notSignedIn)
        XCTAssertEqual(LaneSummaryError.classify("API Error: 429 rate_limit_error"), .rateLimited)
        XCTAssertEqual(LaneSummaryError.classify("You've hit your usage limit"), .rateLimited)
        XCTAssertEqual(LaneSummaryError.classify("boom\nsomething else broke"), .failed("something else broke"))
    }
}

/// A file a test tool creates once it has set itself up, and a wait for it
/// that ``SummaryProcess/run`` calls before the timeout starts. A loaded
/// machine can take seconds to schedule a background-priority shell, so
/// without the wait the stop could reach the tool before its first line ran.
private final class ReadyMarker: @unchecked Sendable {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)").path
    private let lock = NSLock()
    private var armed: Date?
    /// When the timeout began; nil if the tool never said it was ready.
    var armedAt: Date? { lock.withLock { armed } }

    func wait() {
        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: path) {
            guard Date() < deadline else { return }
            usleep(5_000)
        }
        try? FileManager.default.removeItem(atPath: path)
        lock.withLock { armed = Date() }
    }
}

final class SummarizerCommandTests: XCTestCase {
    func testClaudeRunsWithNothingButTheText() {
        let args = ClaudeLaneSummarizer(model: "haiku").arguments
        XCTAssertEqual(Array(args.prefix(3)), ["-p", "--model", "haiku"])
        for (flag, value) in [("--setting-sources", "local"), ("--tools", ""), ("--permission-mode", "default"),
                              ("--settings", #"{"disableAllHooks":true}"#)] {
            let i = try! XCTUnwrap(args.firstIndex(of: flag), flag)
            XCTAssertEqual(args[i + 1], value, flag)
        }
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
    }

    func testCodexRunsEphemeralReadOnlyAtLowEffortWithHooksOff() {
        let args = CodexLaneSummarizer(model: "small-model").arguments(lastMessageFile: "/tmp/out.txt")
        XCTAssertEqual(args.first, "exec")
        XCTAssertEqual(args.last, "-")
        for flag in ["--ignore-user-config", "--ephemeral", "--skip-git-repo-check"] { XCTAssertTrue(args.contains(flag), flag) }
        XCTAssertEqual(args[args.firstIndex(of: "--sandbox")! + 1], "read-only")
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "small-model")
        XCTAssertEqual(args[args.firstIndex(of: "--output-last-message")! + 1], "/tmp/out.txt")
        XCTAssertTrue(args.contains(#"model_reasoning_effort="low""#))
        XCTAssertTrue(args.contains("notify=[]"))
        let disabled = args.indices.filter { args[$0] == "--disable" }.map { args[$0 + 1] }
        XCTAssertTrue(disabled.contains("hooks"))
        XCTAssertTrue(disabled.contains("shell_tool"))
        XCTAssertFalse(CodexLaneSummarizer().arguments(lastMessageFile: "x").contains("--model"))
    }

    func testEnvironmentIsClean() {
        let base = ["HOME": "/Users/test", "PATH": "/usr/bin:/custom/bin", "LANG": "en_CA.UTF-8", "LC_ALL": "C",
                    "AGENTSMATE_LANE": "lane-1", "TMUX": "/tmp/tmux", "CLAUDE_CODE_ENTRYPOINT": "cli",
                    "CLAUDECODE": "1", "CODEX_HOME": "/Users/test/.codex", "SECRET_TOKEN": "x"]
        let env = SummaryProcess.cleanEnvironment(base, binary: URL(fileURLWithPath: "/opt/tools/bin/claude"))
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertEqual(env["CODEX_HOME"], "/Users/test/.codex")
        XCTAssertEqual(env["LC_ALL"], "C")
        for key in ["AGENTSMATE_LANE", "TMUX", "CLAUDE_CODE_ENTRYPOINT", "CLAUDECODE", "SECRET_TOKEN"] {
            XCTAssertNil(env[key], key)
        }
        let path = try! XCTUnwrap(env["PATH"]).split(separator: ":").map(String.init)
        XCTAssertEqual(path.first, "/opt/tools/bin")
        XCTAssertTrue(path.contains("/custom/bin"))
        XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1)
    }

    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testRunReadsInputAndDrainsBothPipes() throws {
        // Far more stderr than a pipe holds: the run must still finish.
        let tool = try script("cat >/dev/null\nhead -c 300000 /dev/zero | tr '\\\\0' x >&2\necho 'Docs site: build fixed'\n")
        defer { try? FileManager.default.removeItem(at: tool) }
        let result = try SummaryProcess.run(tool, arguments: [], input: "hello", environment: [:], timeout: 20,
                                            qualityOfService: .userInitiated)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertGreaterThanOrEqual(result.error.count, 300_000)
        XCTAssertEqual(try result.summary(), "Docs site: build fixed")
    }

    func testRunReturnsWhenAChildHoldsThePipes() throws {
        // The tool exits at once, leaving a child with its stdout and stderr:
        // its reply is kept and the run ends a grace after the exit.
        let tool = try script("cat >/dev/null\nsleep 30 &\necho 'Docs site: build fixed'\n")
        defer { try? FileManager.default.removeItem(at: tool) }
        let started = Date()
        let result = try SummaryProcess.run(tool, arguments: [], input: "", environment: [:], timeout: 20,
                                            qualityOfService: .userInitiated)
        XCTAssertEqual(try result.summary(), "Docs site: build fixed")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testRunTimesOut() throws {
        // One process that would run for ten minutes: only the stop can end
        // it, so returning well inside that proves the timeout fired.
        let tool = try script(": >\"$READY\"\nexec sleep 600\n")
        defer { try? FileManager.default.removeItem(at: tool) }
        let ready = ReadyMarker()
        let result = try SummaryProcess.run(tool, arguments: [], input: "", environment: ["READY": ready.path],
                                            timeout: 0.5, timerQueue: .global(qos: .userInitiated),
                                            qualityOfService: .userInitiated, beforeTimeout: ready.wait)
        let armed = try XCTUnwrap(ready.armedAt, "the tool never started")
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(armed), 60)
        XCTAssertThrowsError(try result.summary()) { XCTAssertEqual($0 as? LaneSummaryError, .timedOut) }
    }

    func testRunKillsAToolThatIgnoresTheStop() throws {
        // The tool ignores SIGTERM for ten minutes; it is killed after the
        // grace and the run returns. The timeout starts only once the trap
        // is set, so the stop always meets a tool that ignores it.
        let tool = try script("trap '' TERM\n: >\"$READY\"\nexec sleep 600\n")
        defer { try? FileManager.default.removeItem(at: tool) }
        let ready = ReadyMarker()
        let result = try SummaryProcess.run(tool, arguments: [], input: "", environment: ["READY": ready.path],
                                            timeout: 0.5, timerQueue: .global(qos: .userInitiated),
                                            qualityOfService: .userInitiated, beforeTimeout: ready.wait)
        let armed = try XCTUnwrap(ready.armedAt, "the tool never started")
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, SIGKILL)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(armed), 0.5 + SummaryProcess.killGrace)
        XCTAssertLessThan(Date().timeIntervalSince(armed), 60)
    }

    func testFailureIsClassified() throws {
        let tool = try script("echo 'Not logged in' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: tool) }
        let result = try SummaryProcess.run(tool, arguments: [], input: "", environment: [:], timeout: 10,
                                            qualityOfService: .userInitiated)
        XCTAssertThrowsError(try result.summary()) { XCTAssertEqual($0 as? LaneSummaryError, .notSignedIn) }
    }

    func testMissingToolThrows() {
        XCTAssertThrowsError(try ClaudeLaneSummarizer(model: "m", binary: URL(fileURLWithPath: "/nonexistent/claude"))
            .summarize(TranscriptDigest(prompts: ["a"], lastReply: nil))) {
            XCTAssertEqual($0 as? LaneSummaryError, .missingCLI)
        }
    }
}

final class SummaryScheduleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ prompt: String, _ reply: String?, at date: Date, source: String = "/s.jsonl") -> LaneSummaryEntry {
        LaneSummaryEntry(source: source, summary: "S", promptPrint: LaneSummaryEntry.fingerprint(prompt),
                         replyPrint: LaneSummaryEntry.fingerprint(reply), generatedAt: date)
    }

    func testFingerprintIsStable() {
        XCTAssertEqual(LaneSummaryEntry.fingerprint(""), 0xcbf29ce484222325)
        XCTAssertEqual(LaneSummaryEntry.fingerprint("a"), 0xaf63dc4c8601ec8c)
        XCTAssertEqual(LaneSummaryEntry.fingerprint(nil), 0)
    }

    func testDue() {
        let digest = TranscriptDigest(prompts: ["p1"], lastReply: "r1")
        XCTAssertTrue(LaneSummaryEntry.isDue(nil, source: "/s.jsonl", digest: digest, now: t0))
        XCTAssertFalse(LaneSummaryEntry.isDue(nil, source: "/s.jsonl", digest: TranscriptDigest(prompts: [], lastReply: nil), now: t0))
        let done = entry("p1", "r1", at: t0)
        XCTAssertFalse(LaneSummaryEntry.isDue(done, source: "/s.jsonl", digest: digest, now: t0.addingTimeInterval(3600)))
        // A new conversation in the lane.
        XCTAssertTrue(LaneSummaryEntry.isDue(done, source: "/other.jsonl", digest: digest, now: t0))
        // A new prompt summarises at once.
        XCTAssertTrue(LaneSummaryEntry.isDue(done, source: "/s.jsonl",
                                             digest: TranscriptDigest(prompts: ["p1", "p2"], lastReply: "r1"), now: t0.addingTimeInterval(1)))
        // Only the reply changed: at most every three minutes.
        let replied = TranscriptDigest(prompts: ["p1"], lastReply: "r2")
        XCTAssertFalse(LaneSummaryEntry.isDue(done, source: "/s.jsonl", digest: replied, now: t0.addingTimeInterval(179)))
        XCTAssertTrue(LaneSummaryEntry.isDue(done, source: "/s.jsonl", digest: replied, now: t0.addingTimeInterval(180)))
    }

    func testCacheRoundTripsAndDropsOldEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summaries-\(UUID().uuidString)/agent-summaries.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LaneSummaryCache(url: url)
        let now = Date()
        cache.write(["new": entry("p", "r", at: now), "old": entry("p", "r", at: now.addingTimeInterval(-40 * 24 * 3600))])
        let read = cache.read(now: now)
        XCTAssertEqual(Array(read.keys), ["new"])
        XCTAssertEqual(read["new"]?.summary, "S")
        // The file holds fingerprints, not conversation text.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("\"p\""))
    }

    func testDefaultCacheFileFallsBackToTheProcessName() {
        XCTAssertEqual(LaneSummaryCache.defaultURL(bundleID: "com.example.App", processName: "x").pathComponents.suffix(2),
                       ["com.example.App", "agent-summaries.json"])
        XCTAssertEqual(LaneSummaryCache.defaultURL(bundleID: nil, processName: "tool").pathComponents.suffix(2),
                       ["tool", "agent-summaries.json"])
        XCTAssertEqual(LaneSummaryCache.defaultURL(bundleID: "", processName: "").pathComponents.suffix(2),
                       ["AgentsMate", "agent-summaries.json"])
        XCTAssertTrue(LaneSummaryCache.defaultURL().path.contains("/Caches/"))
    }
}

/// A summarizer that waits for the test to let it answer.
private final class FakeSummarizer: LaneSummarizing, @unchecked Sendable {
    let agent: String
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    private(set) var calls = 0
    let gate = DispatchSemaphore(value: 0)
    var fails = false

    init(agent: String) { self.agent = agent }

    func summarize(_ digest: TranscriptDigest) throws -> String {
        lock.withLock { active += 1; calls += 1; peak = max(peak, active) }
        gate.wait()
        lock.withLock { active -= 1 }
        if lock.withLock({ fails }) { throw LaneSummaryError.rateLimited }
        return "Work: " + (digest.prompts.last ?? "")
    }
}

@MainActor
final class LaneSummariesTests: XCTestCase {
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testRunsAtMostTwoAtOnce() {
        let fake = FakeSummarizer(agent: "claude")
        let summaries = LaneSummaries(summarizers: [fake], cache: nil)
        summaries.canStart = { true }
        var written: [String: String] = [:]
        summaries.onSummary = { written[$0] = $1 }
        for id in ["a", "b", "c"] {
            summaries.consider(id, agent: "claude", source: "/\(id).jsonl", digest: TranscriptDigest(prompts: [id], lastReply: nil))
        }
        XCTAssertEqual(summaries.running.count, 2)
        for _ in 0..<3 { fake.gate.signal() }
        wait { written.count == 3 }
        XCTAssertEqual(written, ["a": "Work: a", "b": "Work: b", "c": "Work: c"])
        XCTAssertLessThanOrEqual(fake.peak, 2)
        XCTAssertEqual(summaries.summary(for: "b"), "Work: b")
        // Nothing changed: no second run.
        summaries.consider("a", agent: "claude", source: "/a.jsonl", digest: TranscriptDigest(prompts: ["a"], lastReply: nil))
        XCTAssertTrue(summaries.running.isEmpty)
    }

    func testAFailurePausesThatAgentOnly() {
        let claude = FakeSummarizer(agent: "claude")
        let codex = FakeSummarizer(agent: "codex")
        claude.fails = true
        let summaries = LaneSummaries(summarizers: [claude, codex], cache: nil)
        summaries.canStart = { true }
        var written: [String: String] = [:]
        summaries.onSummary = { written[$0] = $1 }
        summaries.consider("a", agent: "claude", source: "/a", digest: TranscriptDigest(prompts: ["a"], lastReply: nil))
        claude.gate.signal()
        wait { summaries.pausedUntil["claude"] != nil }
        XCTAssertNotNil(summaries.pausedUntil["claude"])
        // Paused: a new prompt for a Claude lane waits.
        summaries.consider("b", agent: "claude", source: "/b", digest: TranscriptDigest(prompts: ["b"], lastReply: nil))
        XCTAssertTrue(summaries.running.isEmpty)
        // Codex goes on.
        summaries.consider("c", agent: "codex", source: "/c", digest: TranscriptDigest(prompts: ["c"], lastReply: nil))
        XCTAssertEqual(summaries.running, ["c"])
        codex.gate.signal()
        wait { written["c"] != nil }
        XCTAssertEqual(written, ["c": "Work: c"])
        // An agent with no summarizer is left alone.
        summaries.consider("d", agent: "other", source: "/d", digest: TranscriptDigest(prompts: ["d"], lastReply: nil))
        XCTAssertTrue(summaries.running.isEmpty)
    }

    func testHeldInLowPower() {
        let fake = FakeSummarizer(agent: "claude")
        let summaries = LaneSummaries(summarizers: [fake], cache: nil)
        var allowed = false
        summaries.canStart = { allowed }
        summaries.consider("a", agent: "claude", source: "/a", digest: TranscriptDigest(prompts: ["a"], lastReply: nil))
        XCTAssertTrue(summaries.running.isEmpty)
        allowed = true
        summaries.tick()
        XCTAssertEqual(summaries.running, ["a"])
        fake.gate.signal()
        wait { summaries.running.isEmpty }
    }

    func testRelaunchShowsTheSavedLineAtOnce() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("summaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("agent-summaries.json")
        LaneSummaryCache(url: file).write(["a": LaneSummaryEntry(source: "/a", summary: "Docs site: build fixed",
                                                                 promptPrint: 1, replyPrint: 2, generatedAt: Date())])
        let defaults = UserDefaults(suiteName: "agentsmate-tests-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "Test", sessionFileDirectory: nil, summaryModel: "m",
                                                        summaryCacheFile: file, rowStyle: .summaryFirst),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "shell")])
        XCTAssertEqual(store.sessions["a"]?.summary, "Docs site: build fixed")
        XCTAssertTrue(store.summariesEnabled)

        // The person's off switch hides it, and on brings it back.
        store.summariesEnabled = false
        XCTAssertEqual(defaults.object(forKey: store.keys.summarizeSessions) as? Bool, false)
        XCTAssertNil(store.sessions["a"]?.summary)
        store.summariesEnabled = true
        XCTAssertEqual(store.sessions["a"]?.summary, "Docs site: build fixed")
        XCTAssertEqual(store.paletteResults("build fixed").map(\.id), ["a"])
    }

    func testNoModelMeansOff() {
        let defaults = UserDefaults(suiteName: "agentsmate-tests-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "Test", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        XCTAssertFalse(store.summariesAvailable)
        XCTAssertFalse(store.summariesEnabled)
        XCTAssertEqual(store.configuration.rowStyle, .standard)
        XCTAssertEqual(store.keys.summarizeSessions, "agentsmate.summarizeSessions")
    }
}

final class SidebarSearchTests: XCTestCase {
    @MainActor
    func testMatchesSummaryAndPrompts() {
        let fields = ["Docs", "/work/docs", "Billing export: CSV writer done", "Add the upload step"]
        XCTAssertTrue(AgentLaneSidebar<EmptyView>.matches(query: "csv writer", in: fields))
        XCTAssertTrue(AgentLaneSidebar<EmptyView>.matches(query: "UPLOAD", in: fields))
        XCTAssertTrue(AgentLaneSidebar<EmptyView>.matches(query: "  ", in: fields))
        XCTAssertFalse(AgentLaneSidebar<EmptyView>.matches(query: "parser", in: fields))
    }

    @MainActor
    func testHoverReplyIsOneParagraphCutShort() {
        XCTAssertNil(LaneRow.hoverReply(nil))
        XCTAssertNil(LaneRow.hoverReply(" \n "))
        XCTAssertEqual(LaneRow.hoverReply("Done.\n\nNext:  the upload"), "Done. Next: the upload")
        XCTAssertEqual(LaneRow.hoverReply(String(repeating: "a", count: 500), limit: 10), "aaaaaaaaaa…")
    }
}
