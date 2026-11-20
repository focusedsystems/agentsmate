import Foundation
import AgentsMateStatus

/// Where a pull request stands: open, draft, merged or closed.
public typealias PullRequestState = LaneRowMetadata.PullRequest.State

extension LaneRowMetadata.PullRequest.State {
    /// Merged and closed pull requests do not change again, so they are
    /// never asked about twice.
    public var isFinal: Bool { self == .merged || self == .closed }

    /// The state as a menu or a hover names it.
    public var title: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

/// What a resolver found out about one pull request.
public struct PullRequestDetails: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String?
    public var state: PullRequestState
    /// The repository as its host writes it, such as `owner/repo`.
    public var repository: String?
    /// The branch the pull request merges from, when the resolver says. A
    /// lane on that branch in that repository then shows this pull request
    /// without a lookup of its own.
    public var headBranch: String?

    public init(number: Int, title: String? = nil, state: PullRequestState, repository: String? = nil,
                headBranch: String? = nil) {
        self.number = number
        self.title = title
        self.state = state
        self.repository = repository
        self.headBranch = headBranch
    }
}

/// Looks up a pull request's title and state from its link. The package
/// ships ``GitHubPullRequestResolver``; an app adds others, such as one for
/// Azure DevOps, through ``AgentLaneStore/Configuration/pullRequestResolvers``.
///
/// `resolve` is called off the main actor, at most two at a time across
/// every resolver, and only for links ``PullRequestLink/isTrusted(_:)``
/// accepts. A resolver that throws is not asked again for ten minutes.
public protocol PullRequestResolver: Sendable {
    /// A stable name, used to pause this resolver after a failure.
    var id: String { get }
    /// Whether this resolver can look up `url`. Called on the main actor, so
    /// it must be quick and must not touch the network.
    func canResolve(_ url: URL) -> Bool
    func resolve(_ url: URL) async throws -> PullRequestDetails
}

/// Why a resolver could not answer.
public enum PullRequestResolverError: Error, Equatable, Sendable {
    /// The tool it needs is not installed.
    case unavailable
    /// The tool ran but gave no answer it could read: not signed in, no
    /// access, a timeout, or a link it does not know.
    case noAnswer
}

/// Resolves github.com pull requests with `gh pr view <url> --json …`, at
/// background priority with a timeout. Uses the person's own `gh` sign-in.
public struct GitHubPullRequestResolver: PullRequestResolver {
    public var id: String { "gh" }
    /// The `gh` executable; nil when it is not installed.
    public var executable: String?
    /// How long one lookup may take before `gh` is stopped.
    public var timeout: TimeInterval

    public init(executable: String? = LaneRowMetadataReader.locateGH(), timeout: TimeInterval = 15) {
        self.executable = executable
        self.timeout = timeout
    }

    public func canResolve(_ url: URL) -> Bool {
        executable != nil && url.host(percentEncoded: true)?.lowercased() == "github.com"
    }

    /// The arguments for one lookup. The link goes after `--`, so it can
    /// never be read as an option.
    static func arguments(for url: URL) -> [String] {
        ["pr", "view", "--json", "title,state,number,isDraft,headRefName", "--", url.absoluteString]
    }

    public func resolve(_ url: URL) async throws -> PullRequestDetails {
        guard let executable else { throw PullRequestResolverError.unavailable }
        let arguments = Self.arguments(for: url), timeout = timeout
        // The helper blocks while it waits for a process slot, so it runs on
        // a dispatch queue rather than in Swift's concurrency pool.
        let output = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                continuation.resume(returning: LaneRowMetadataReader.run(executable, arguments, timeout: timeout))
            }
        }
        guard let details = Self.parse(output, url: url) else { throw PullRequestResolverError.noAnswer }
        return details
    }

    static func parse(_ output: String, url: URL) -> PullRequestDetails? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["number"] as? Int, let state = object["state"] as? String else { return nil }
        let kind: PullRequestState
        switch state.uppercased() {
        case "MERGED": kind = .merged
        case "CLOSED": kind = .closed
        case "DRAFT": kind = .draft
        default: kind = (object["isDraft"] as? Bool) == true ? .draft : .open
        }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let head = (object["headRefName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PullRequestDetails(number: number, title: title, state: kind, repository: PullRequestKey.repository(of: url),
                                  headBranch: head)
    }
}

/// One pull request a lane's row, inbox entry or menu shows.
public struct LanePullRequest: Equatable, Sendable, Identifiable {
    /// Where the link came from.
    public enum Source: Sendable, Equatable {
        /// The agent posted it in a reply.
        case agent
        /// `gh` found it for the branch checked out in the lane's folder.
        case branch
    }

    public var url: URL
    /// Nil until a resolver has answered.
    public var details: PullRequestDetails?
    public var source: Source

    public init(url: URL, details: PullRequestDetails? = nil, source: Source = .agent) {
        self.url = url
        self.details = details
        self.source = source
    }

    public var id: URL { url }
    public var number: Int? { details?.number ?? PullRequestLinkLabel.number(of: url) }
    public var state: PullRequestState? { details?.state }
    public var title: String? { details?.title }

    /// `#12`, or the link's last part when it has no number.
    public var label: String { number.map { "#\($0)" } ?? url.lastPathComponent }

    /// The SF Symbol for its state.
    public var symbolName: String {
        switch state {
        case .open, nil: "arrow.triangle.pull"
        case .draft: "circle.dashed"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    /// What VoiceOver reads: `Pull request 12, merged, Fix the parser`.
    public var accessibilityDescription: String {
        var parts = ["Pull request " + (number.map(String.init) ?? url.lastPathComponent)]
        parts.append(state.map { $0.title.lowercased() } ?? "state not known yet")
        if let title { parts.append(title) }
        return parts.joined(separator: ", ")
    }

    /// One line for a menu or the hover: `#12 Merged — Fix the parser`.
    public var menuTitle: String {
        var text = label
        if let state { text += " " + state.title }
        if let title { text += " — " + (title.count > 70 ? String(title.prefix(69)) + "…" : title) }
        return text
    }
}

/// A pull request link reduced to what identifies it, so the same pull
/// request matches whichever way it was written.
enum PullRequestKey {
    static func of(_ url: URL) -> String {
        var path = url.path(percentEncoded: true).lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return (url.host(percentEncoded: true)?.lowercased() ?? "") + path
    }

    /// `owner/repo` for a GitHub link, `project/repo` for Azure DevOps.
    static func repository(of url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let pull = parts.firstIndex(of: "pull"), pull >= 2 { return parts[pull - 2] + "/" + parts[pull - 1] }
        if let git = parts.firstIndex(of: "_git"), git >= 1, git + 1 < parts.count { return parts[git - 1] + "/" + parts[git + 1] }
        return nil
    }

    /// The pull requests to show for a lane: the agent's, then the branch's
    /// when the agent has not posted that one too.
    static func merge(agent: [LanePullRequest], branch: LanePullRequest?) -> [LanePullRequest] {
        guard let branch else { return agent }
        let key = of(branch.url)
        return agent.contains { of($0.url) == key } ? agent : agent + [branch]
    }
}

/// How often pull requests are looked up, and how many at once.
enum PullRequestSchedule {
    /// Open and draft pull requests are asked about again this often.
    static let recheck: TimeInterval = 300
    /// How long a resolver rests after a failure.
    static let failurePause: TimeInterval = 600
    /// Lookups running at once, across every resolver.
    static let maxConcurrent = 2
    /// Links kept per lane; the oldest go first.
    static let perLane = 20
    /// A lane that gained no link for this long is dropped when the ledger
    /// is read.
    static let keep: TimeInterval = 30 * 24 * 3600
}

/// What the ledger keeps between launches.
struct PullRequestLedgerState: Codable, Equatable, Sendable {
    struct Lane: Codable, Equatable, Sendable {
        /// Oldest first.
        var urls: [URL]
        var updatedAt: Date
    }

    struct Resolution: Codable, Equatable, Sendable {
        var details: PullRequestDetails
        var checkedAt: Date
    }

    var lanes: [String: Lane] = [:]
    /// By ``PullRequestKey``.
    var resolutions: [String: Resolution] = [:]

    /// The newest of the lane's pull requests that merges from `branch` in
    /// `repository` (`owner/repo`, compared without case), as the row's
    /// branch chip shows it. Nil when the ledger does not know one, so the
    /// branch is looked up instead.
    func pullRequest(for lane: String, branch: String, repository: String) -> LaneRowMetadata.PullRequest? {
        let repository = repository.lowercased()
        for url in (lanes[lane]?.urls ?? []).reversed() {
            guard let details = resolutions[PullRequestKey.of(url)]?.details,
                  details.headBranch == branch, details.repository?.lowercased() == repository else { continue }
            return .init(number: details.number, state: details.state, url: url)
        }
        return nil
    }
}

/// The ledger file: `~/Library/Caches/<bundle id>/agent-pull-requests.json`.
struct PullRequestLedgerCache: Sendable {
    let url: URL

    static func defaultURL(bundleID: String? = Bundle.main.bundleIdentifier,
                           processName: String = ProcessInfo.processInfo.processName) -> URL {
        LaneSummaryCache.defaultURL(bundleID: bundleID, processName: processName)
            .deletingLastPathComponent().appendingPathComponent("agent-pull-requests.json")
    }

    func read(now: Date = Date()) -> PullRequestLedgerState {
        guard let data = try? Data(contentsOf: url) else { return .init() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var state = try? decoder.decode(PullRequestLedgerState.self, from: data) else { return .init() }
        state.lanes = state.lanes.filter { now.timeIntervalSince($0.value.updatedAt) < PullRequestSchedule.keep }
        for (id, lane) in state.lanes { state.lanes[id]?.urls = lane.urls.filter(PullRequestLink.isTrusted) }
        let referenced = Set(state.lanes.values.flatMap(\.urls).map(PullRequestKey.of))
        state.resolutions = state.resolutions.filter { referenced.contains($0.key) }
        return state
    }

    func write(_ state: PullRequestLedgerState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}

/// Claude Code's own pull request status cache (`gh-pr-status-cache.json`
/// in its config folder), read once as a warm start for GitHub links. It is
/// a JSON object keyed by pull request link, each value carrying `number`,
/// `title` and `state` (`OPEN`, `DRAFT`, `MERGED`, `CLOSED`). It has no
/// dates, so its entries count as checked when the file was last written.
enum ClaudePullRequestSeed {
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let folder = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return folder.appendingPathComponent("gh-pr-status-cache.json")
    }

    static func read(_ url: URL) -> [String: PullRequestLedgerState.Resolution] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return parse(data, checkedAt: date)
    }

    static func parse(_ data: Data, checkedAt: Date) -> [String: PullRequestLedgerState.Resolution] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: PullRequestLedgerState.Resolution] = [:]
        for (link, value) in object {
            guard let url = URL(string: link), PullRequestLink.isTrusted(url),
                  url.host(percentEncoded: true)?.lowercased() == "github.com",
                  let entry = value as? [String: Any], let number = entry["number"] as? Int,
                  let raw = entry["state"] as? String else { continue }
            let state: PullRequestState
            switch raw.uppercased() {
            case "OPEN": state = .open
            case "DRAFT": state = .draft
            case "MERGED": state = .merged
            case "CLOSED": state = .closed
            default: continue
            }
            let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out[PullRequestKey.of(url)] = .init(details: .init(number: number, title: title, state: state,
                                                               repository: PullRequestKey.repository(of: url)),
                                                checkedAt: checkedAt)
        }
        return out
    }
}

/// Every lane's pull request links and what they resolved to. Links come
/// from the store's transcript reads; lookups start when a new link arrives
/// and, for open and draft pull requests only, every five minutes on a
/// ``CadenceTimer`` that runs only while there is one to recheck. Merged and
/// closed pull requests are never looked up again.
@MainActor
final class PullRequestLedger {
    private(set) var state: PullRequestLedgerState
    private(set) var running: Set<String> = []
    private(set) var queue: [String] = []
    private(set) var pausedUntil: [String: Date] = [:]
    private var links: [String: URL] = [:]
    private let resolvers: [any PullRequestResolver]
    private let cache: PullRequestLedgerCache?
    private var seed: [String: PullRequestLedgerState.Resolution]
    private var saveScheduled = false
    private var timer: CadenceTimer?
    private let cadence: BackgroundCadence
    var maxConcurrent = PullRequestSchedule.maxConcurrent
    /// Whether lookups may start; Low Power Mode holds them until the next tick.
    var canStart: () -> Bool = { !ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// The lanes whose pull requests changed.
    var onChange: ((Set<String>) -> Void)?
    var now: () -> Date = Date.init

    init(resolvers: [any PullRequestResolver], cache: PullRequestLedgerCache?, seedFile: URL? = nil,
         cadence: BackgroundCadence = .shared) {
        self.resolvers = resolvers
        self.cache = cache
        self.cadence = cadence
        self.state = cache?.read() ?? .init()
        self.seed = seedFile.map(ClaudePullRequestSeed.read) ?? [:]
        for url in state.lanes.values.flatMap(\.urls) {
            let key = PullRequestKey.of(url)
            links[key] = url
            adoptSeed(key)
        }
        syncTimer()
    }

    /// The lane's pull requests, oldest first.
    func pullRequests(for lane: String) -> [LanePullRequest] {
        (state.lanes[lane]?.urls ?? []).map { url in
            LanePullRequest(url: url, details: state.resolutions[PullRequestKey.of(url)]?.details)
        }
    }

    /// Whether the recheck timer is running.
    var isTiming: Bool { timer != nil }

    /// Add the links a lane's transcript holds. Only trusted links are kept,
    /// each once, and a new one is looked up at once.
    func record(_ urls: [URL], lane: String) {
        var entry = state.lanes[lane] ?? .init(urls: [], updatedAt: now())
        var known = Set(entry.urls.map(PullRequestKey.of))
        var added = false
        for url in urls where PullRequestLink.isTrusted(url) {
            let key = PullRequestKey.of(url)
            guard known.insert(key).inserted else { continue }
            entry.urls.append(url)
            links[key] = links[key] ?? url
            adoptSeed(key)
            added = true
        }
        guard added else { return }
        if entry.urls.count > PullRequestSchedule.perLane { entry.urls.removeFirst(entry.urls.count - PullRequestSchedule.perLane) }
        entry.updatedAt = now()
        state.lanes[lane] = entry
        onChange?([lane])
        scheduleSave()
        tick()
    }

    /// Look up every link that is due, then keep the timer only while an
    /// open or unresolved pull request remains.
    func tick() {
        for key in Set(state.lanes.values.flatMap(\.urls).map(PullRequestKey.of)).sorted()
        where isDue(key) && !running.contains(key) && !queue.contains(key) {
            queue.append(key)
        }
        pump()
        syncTimer()
    }

    func resolver(for url: URL) -> (any PullRequestResolver)? {
        resolvers.first { $0.canResolve(url) }
    }

    func isDue(_ key: String) -> Bool {
        guard let url = links[key], let resolver = resolver(for: url) else { return false }
        if let paused = pausedUntil[resolver.id], now() < paused { return false }
        guard let resolution = state.resolutions[key] else { return true }
        if resolution.details.state.isFinal { return false }
        return now().timeIntervalSince(resolution.checkedAt) >= PullRequestSchedule.recheck
    }

    /// Whether any link still needs a lookup now or later.
    var needsRechecks: Bool {
        state.lanes.values.flatMap(\.urls).contains { url in
            guard resolver(for: url) != nil else { return false }
            return !(state.resolutions[PullRequestKey.of(url)]?.details.state.isFinal ?? false)
        }
    }

    private func adoptSeed(_ key: String) {
        guard state.resolutions[key] == nil, let seeded = seed[key] else { return }
        state.resolutions[key] = seeded
    }

    private func syncTimer() {
        if needsRechecks {
            guard timer == nil else { return }
            timer = CadenceTimer(interval: PullRequestSchedule.recheck, cadence: cadence) { [weak self] in self?.tick() }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func pump() {
        guard canStart() else { return }
        while running.count < maxConcurrent, !queue.isEmpty {
            let key = queue.removeFirst()
            guard isDue(key), let url = links[key], let resolver = resolver(for: url) else { continue }
            running.insert(key)
            Task.detached(priority: .background) { [weak self] in
                let result: Result<PullRequestDetails, any Error>
                do { result = .success(try await resolver.resolve(url)) } catch { result = .failure(error) }
                await self?.finish(key, resolverID: resolver.id, result: result)
            }
        }
    }

    func finish(_ key: String, resolverID: String, result: Result<PullRequestDetails, any Error>) {
        running.remove(key)
        switch result {
        case .success(let details):
            let changed = state.resolutions[key]?.details != details
            state.resolutions[key] = .init(details: details, checkedAt: now())
            if changed {
                let lanes = state.lanes.filter { $0.value.urls.contains { PullRequestKey.of($0) == key } }.map(\.key)
                onChange?(Set(lanes))
            }
            scheduleSave()
        case .failure:
            // Not signed in, no access, no network: asking again at once
            // would only fail again. What it said last time stays.
            pausedUntil[resolverID] = now().addingTimeInterval(PullRequestSchedule.failurePause)
            queue.removeAll { key in links[key].flatMap(resolver(for:))?.id == resolverID }
        }
        pump()
        syncTimer()
    }

    private func scheduleSave() {
        guard let cache, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                let state = self.state
                DispatchQueue.global(qos: .background).async { cache.write(state) }
            }
        }
    }
}
