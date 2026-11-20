import XCTest
import AgentsMateStatus
@testable import AgentsMate

/// A resolver that answers from a table and counts its calls.
private final class FakeResolver: PullRequestResolver, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var answers: [String: PullRequestDetails]
    private var fails: Bool
    private var recorded: [URL] = []

    init(id: String = "fake", answers: [String: PullRequestDetails] = [:], fails: Bool = false) {
        self.id = id
        self.answers = answers
        self.fails = fails
    }

    func set(_ url: URL, _ details: PullRequestDetails) { lock.withLock { answers[url.absoluteString] = details } }
    func setFails(_ value: Bool) { lock.withLock { fails = value } }
    var calls: [URL] { lock.withLock { recorded } }

    func canResolve(_ url: URL) -> Bool { url.host() == "github.com" }

    func resolve(_ url: URL) async throws -> PullRequestDetails {
        let (answer, fails) = lock.withLock { () -> (PullRequestDetails?, Bool) in
            recorded.append(url)
            return (answers[url.absoluteString], self.fails)
        }
        if fails { throw PullRequestResolverError.noAnswer }
        guard let answer else { throw PullRequestResolverError.noAnswer }
        return answer
    }
}

@MainActor
final class PullRequestLedgerTests: XCTestCase {
    private let a = URL(string: "https://github.com/acme/widgets/pull/1")!
    private let b = URL(string: "https://github.com/acme/widgets/pull/2")!
    private let c = URL(string: "https://github.com/acme/widgets/pull/3")!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLedger(_ resolver: FakeResolver, cache: PullRequestLedgerCache? = nil,
                            seed: URL? = nil) -> PullRequestLedger {
        let ledger = PullRequestLedger(resolvers: [resolver], cache: cache, seedFile: seed, cadence: BackgroundCadence())
        ledger.canStart = { true }
        ledger.now = { [unowned self] in self.clock }
        return ledger
    }

    private func settle(_ ledger: PullRequestLedger) async throws {
        for _ in 0..<500 where !(ledger.running.isEmpty && ledger.queue.isEmpty) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(ledger.running.isEmpty)
    }

    private func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agentsmate-\(UUID().uuidString)-\(name)")
    }

    func testKeepsTrustedLinksOnceAndLooksThemUp() async throws {
        let resolver = FakeResolver()
        resolver.set(a, .init(number: 1, title: "Add export", state: .open))
        let ledger = makeLedger(resolver)
        var changed: [Set<String>] = []
        ledger.onChange = { changed.append($0) }
        ledger.record([a, URL(string: "https://github.com.evil.example/acme/w/pull/9")!,
                       URL(string: "https://github.com/acme/widgets/pull/1/")!], lane: "x")
        XCTAssertEqual(ledger.pullRequests(for: "x").map(\.url), [a], "untrusted dropped, trailing slash is the same PR")
        try await settle(ledger)
        XCTAssertEqual(ledger.pullRequests(for: "x").first?.state, .open)
        XCTAssertEqual(ledger.pullRequests(for: "x").first?.title, "Add export")
        XCTAssertEqual(changed, [["x"], ["x"]])
        ledger.record([a], lane: "x")
        XCTAssertEqual(changed.count, 2, "a link already kept changes nothing")
        XCTAssertEqual(resolver.calls.count, 1)
    }

    func testKeepsTheNewestTwentyPerLane() {
        let ledger = makeLedger(FakeResolver())
        ledger.canStart = { false }
        let urls = (1...25).map { URL(string: "https://github.com/acme/w/pull/\($0)")! }
        ledger.record(urls, lane: "x")
        XCTAssertEqual(ledger.pullRequests(for: "x").count, PullRequestSchedule.perLane)
        XCTAssertEqual(ledger.pullRequests(for: "x").first?.number, 6)
    }

    func testAtMostTwoLookupsAtOnce() async throws {
        let resolver = FakeResolver()
        for (i, url) in [a, b, c].enumerated() { resolver.set(url, .init(number: i + 1, state: .merged)) }
        let ledger = makeLedger(resolver)
        ledger.record([a, b, c], lane: "x")
        XCTAssertEqual(ledger.running.count, 2)
        XCTAssertEqual(ledger.queue.count, 1)
        try await settle(ledger)
        XCTAssertEqual(resolver.calls.count, 3)
    }

    func testOpenIsRecheckedEveryFiveMinutesAndFinalNever() async throws {
        let resolver = FakeResolver()
        resolver.set(a, .init(number: 1, state: .open))
        resolver.set(b, .init(number: 2, state: .merged))
        let ledger = makeLedger(resolver)
        ledger.record([a, b], lane: "x")
        try await settle(ledger)
        XCTAssertEqual(resolver.calls.count, 2)
        XCTAssertTrue(ledger.isTiming, "an open PR keeps the recheck timer")

        clock += PullRequestSchedule.recheck - 1
        ledger.tick()
        try await settle(ledger)
        XCTAssertEqual(resolver.calls.count, 2, "not yet due")

        clock += 1
        resolver.set(a, .init(number: 1, state: .merged))
        ledger.tick()
        try await settle(ledger)
        XCTAssertEqual(resolver.calls.suffix(1), [a], "only the open PR is asked again")
        XCTAssertFalse(ledger.isTiming, "every PR is final, so the timer stops")

        clock += 3600
        ledger.tick()
        try await settle(ledger)
        XCTAssertEqual(resolver.calls.count, 3)
    }

    func testFailurePausesTheResolverTenMinutes() async throws {
        let resolver = FakeResolver(fails: true)
        let ledger = makeLedger(resolver)
        ledger.record([a], lane: "x")
        try await settle(ledger)
        XCTAssertEqual(ledger.pausedUntil["fake"], clock + PullRequestSchedule.failurePause)
        ledger.record([b], lane: "x")
        XCTAssertTrue(ledger.running.isEmpty, "paused, so nothing starts")
        XCTAssertNil(ledger.pullRequests(for: "x").first?.state)

        clock += PullRequestSchedule.failurePause
        resolver.setFails(false)
        resolver.set(a, .init(number: 1, state: .closed))
        resolver.set(b, .init(number: 2, state: .draft))
        ledger.tick()
        try await settle(ledger)
        XCTAssertEqual(ledger.pullRequests(for: "x").map(\.state), [.closed, .draft])
    }

    func testLinksNoResolverTakesAreKeptButNeverLookedUp() {
        let ledger = makeLedger(FakeResolver())
        let other = URL(string: "https://org.visualstudio.com/Proj/_git/repo/pullrequest/12")!
        ledger.record([other], lane: "x")
        XCTAssertEqual(ledger.pullRequests(for: "x").map(\.number), [12])
        XCTAssertTrue(ledger.running.isEmpty)
        XCTAssertFalse(ledger.isTiming)
    }

    func testSurvivesARelaunch() {
        let file = tempFile("ledger.json")
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = PullRequestLedgerCache(url: file)
        var state = PullRequestLedgerState()
        state.lanes["x"] = .init(urls: [a, URL(string: "http://github.com/acme/w/pull/5")!], updatedAt: Date())
        state.lanes["old"] = .init(urls: [b], updatedAt: Date(timeIntervalSinceNow: -PullRequestSchedule.keep - 1))
        state.resolutions[PullRequestKey.of(a)] = .init(details: .init(number: 1, title: "Kept", state: .merged), checkedAt: Date())
        state.resolutions[PullRequestKey.of(b)] = .init(details: .init(number: 2, state: .open), checkedAt: Date())
        cache.write(state)

        let read = cache.read()
        XCTAssertEqual(Array(read.lanes.keys), ["x"], "a lane quiet for a month is dropped")
        XCTAssertEqual(read.lanes["x"]?.urls, [a], "an untrusted link written by hand is dropped")
        XCTAssertEqual(Array(read.resolutions.keys), [PullRequestKey.of(a)])

        let resolver = FakeResolver()
        let ledger = makeLedger(resolver, cache: cache)
        XCTAssertEqual(ledger.pullRequests(for: "x").first?.title, "Kept")
        ledger.tick()
        XCTAssertTrue(ledger.running.isEmpty, "a merged PR from the last launch is final")
    }

    func testWarmStartFromClaudeCodesCache() async throws {
        let file = tempFile("gh-pr-status-cache.json")
        defer { try? FileManager.default.removeItem(at: file) }
        let json = """
        {"\(a.absoluteString)":{"number":1,"title":"Seeded","state":"MERGED","checks":{"passed":1,"failed":0,"pending":0},"review":null,"additions":1,"deletions":0},
         "\(b.absoluteString)":{"number":2,"title":"Still open","state":"OPEN","checks":{"passed":0,"failed":0,"pending":0},"review":null,"additions":1,"deletions":0},
         "https://example.com/acme/w/pull/4":{"number":4,"title":"Elsewhere","state":"OPEN"},
         "\(c.absoluteString)":{"number":3,"state":"SOMETHING"}}
        """
        try Data(json.utf8).write(to: file)
        let seeded = ClaudePullRequestSeed.read(file)
        XCTAssertEqual(Set(seeded.keys), [PullRequestKey.of(a), PullRequestKey.of(b)])
        XCTAssertEqual(seeded[PullRequestKey.of(a)]?.details.repository, "acme/widgets")

        let resolver = FakeResolver()
        clock = Date()
        let ledger = makeLedger(resolver, seed: file)
        ledger.record([a, b], lane: "x")
        XCTAssertEqual(ledger.pullRequests(for: "x").map(\.state), [.merged, .open], "states show before any lookup")
        XCTAssertEqual(ledger.pullRequests(for: "x").first?.title, "Seeded")
        try await settle(ledger)
        XCTAssertEqual(resolver.calls, [], "a merged seed is final and an open one was checked just now")

        XCTAssertTrue(ClaudePullRequestSeed.read(tempFile("missing.json")).isEmpty)
        XCTAssertEqual(ClaudePullRequestSeed.defaultURL(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cfg"]).path,
                       "/tmp/cfg/gh-pr-status-cache.json")
    }
}

final class PullRequestDisplayTests: XCTestCase {
    func testGitHubResolverCommandAndAnswers() {
        let url = URL(string: "https://github.com/acme/widgets/pull/7")!
        XCTAssertEqual(GitHubPullRequestResolver.arguments(for: url),
                       ["pr", "view", "--json", "title,state,number,isDraft", "--", url.absoluteString])
        XCTAssertEqual(GitHubPullRequestResolver.parse(#"{"number":7,"state":"OPEN","isDraft":true,"title":"WIP"}"#, url: url),
                       .init(number: 7, title: "WIP", state: .draft, repository: "acme/widgets"))
        XCTAssertEqual(GitHubPullRequestResolver.parse(#"{"number":7,"state":"MERGED","isDraft":false,"title":""}"#, url: url)?.state, .merged)
        XCTAssertNil(GitHubPullRequestResolver.parse("not signed in", url: url))
        let resolver = GitHubPullRequestResolver(executable: "/usr/bin/true")
        XCTAssertTrue(resolver.canResolve(url))
        XCTAssertFalse(resolver.canResolve(URL(string: "https://org.visualstudio.com/Proj/_git/repo/pullrequest/1")!))
        XCTAssertFalse(GitHubPullRequestResolver(executable: nil).canResolve(url))
    }

    func testRepositoryAndKey() {
        XCTAssertEqual(PullRequestKey.repository(of: URL(string: "https://github.com/acme/widgets/pull/7")!), "acme/widgets")
        XCTAssertEqual(PullRequestKey.repository(of: URL(string: "https://org.visualstudio.com/Proj/_git/repo/pullrequest/3")!), "Proj/repo")
        XCTAssertEqual(PullRequestKey.of(URL(string: "https://GitHub.com/Acme/W/pull/1/")!),
                       PullRequestKey.of(URL(string: "https://github.com/acme/w/pull/1")!))
    }

    func testBranchPullRequestIsDroppedWhenTheAgentPostedIt() {
        let agent = [LanePullRequest(url: URL(string: "https://github.com/acme/w/pull/1")!)]
        let same = LanePullRequest(url: URL(string: "https://github.com/acme/w/pull/1")!,
                                   details: .init(number: 1, state: .open), source: .branch)
        let other = LanePullRequest(url: URL(string: "https://github.com/acme/w/pull/2")!, source: .branch)
        XCTAssertEqual(PullRequestKey.merge(agent: agent, branch: same), agent)
        XCTAssertEqual(PullRequestKey.merge(agent: agent, branch: other).map(\.number), [1, 2])
        XCTAssertEqual(PullRequestKey.merge(agent: [], branch: other), [other], "the branch chip stays with no agent link")
    }

    func testLabelsSymbolsAndAccessibility() {
        let url = URL(string: "https://github.com/acme/w/pull/12")!
        let unknown = LanePullRequest(url: url)
        XCTAssertEqual(unknown.label, "#12")
        XCTAssertEqual(unknown.menuTitle, "#12")
        XCTAssertEqual(unknown.accessibilityDescription, "Pull request 12, state not known yet")
        let merged = LanePullRequest(url: url, details: .init(number: 12, title: "Fix the parser", state: .merged))
        XCTAssertEqual(merged.menuTitle, "#12 Merged — Fix the parser")
        XCTAssertEqual(merged.accessibilityDescription, "Pull request 12, merged, Fix the parser")
        XCTAssertEqual(merged.symbolName, "arrow.triangle.merge")
        let states: [PullRequestState] = [.open, .draft, .merged, .closed]
        XCTAssertEqual(Set(states.map { LanePullRequest(url: url, details: .init(number: 1, state: $0)).symbolName }).count, 4)
        XCTAssertTrue(PullRequestState.closed.isFinal)
        XCTAssertFalse(PullRequestState.draft.isFinal)
    }

    @MainActor
    func testSessionShowsTheLedgerThenTheBranch() {
        let session = AgentLaneSession(lane: AgentLane(id: "x", title: "X", backendID: "shell"), backend: CommandLaneBackend.shell)
        session.rowMetadata = LaneRowMetadata(pullRequest: .init(number: 2, state: .open, url: URL(string: "https://github.com/acme/w/pull/2")!))
        XCTAssertEqual(session.displayedPullRequests.map(\.source), [.branch])
        session.pullRequests = [LanePullRequest(url: URL(string: "https://github.com/acme/w/pull/2")!,
                                                details: .init(number: 2, state: .merged))]
        XCTAssertEqual(session.displayedPullRequests.map(\.state), [.merged], "deduped to the ledger's entry")
    }
}
