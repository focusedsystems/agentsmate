import Foundation
import AgentsMateStatus

/// When summaries run, and how many at once.
enum SummarySchedule {
    /// Summaries running at the same time, across every agent.
    static let maxConcurrent = 2
    /// While only the agent's reply changes, a lane is summarised at most
    /// this often. A new prompt summarises at once.
    static let replyInterval: TimeInterval = 180
    /// How long an agent's summaries wait after one fails.
    static let failurePause: TimeInterval = 600
    /// Saved summaries older than this are dropped when the cache is read.
    static let keep: TimeInterval = 30 * 24 * 3600
}

/// The last summary written for a lane, and what it was written from.
/// Prompts and replies are kept as fingerprints, so the cache holds no
/// conversation text.
struct LaneSummaryEntry: Codable, Equatable, Sendable {
    /// The conversation file it was written from.
    var source: String
    var summary: String
    var promptPrint: UInt64
    var replyPrint: UInt64
    var generatedAt: Date

    /// A stable 64-bit FNV-1a fingerprint, the same in every launch.
    static func fingerprint(_ text: String?) -> UInt64 {
        guard let text else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// Whether a lane's conversation needs a new summary: none yet, a new
    /// conversation, a new prompt, or a changed reply once the reply
    /// interval has passed.
    static func isDue(_ entry: LaneSummaryEntry?, source: String, digest: TranscriptDigest, now: Date,
                      replyInterval: TimeInterval = SummarySchedule.replyInterval) -> Bool {
        guard !digest.prompts.isEmpty || digest.lastReply != nil else { return false }
        guard let entry, entry.source == source else { return true }
        if fingerprint(digest.prompts.last) != entry.promptPrint { return true }
        if fingerprint(digest.lastReply) != entry.replyPrint {
            return now.timeIntervalSince(entry.generatedAt) >= replyInterval
        }
        return false
    }
}

/// The summaries file: `~/Library/Caches/<bundle id>/agent-summaries.json`.
struct LaneSummaryCache: Sendable {
    let url: URL

    /// The app's own caches folder; a process without a bundle id (a test
    /// runner, a command-line tool) uses its process name.
    static func defaultURL(bundleID: String? = Bundle.main.bundleIdentifier,
                           processName: String = ProcessInfo.processInfo.processName) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? (processName.isEmpty ? "AgentsMate" : processName)
        return caches.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("agent-summaries.json")
    }

    func read(now: Date = Date()) -> [String: LaneSummaryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([String: LaneSummaryEntry].self, from: data) else { return [:] }
        return entries.filter { now.timeIntervalSince($0.value.generatedAt) < SummarySchedule.keep }
    }

    func write(_ entries: [String: LaneSummaryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}

/// Decides which lanes get a new summary and runs them: at most two at
/// once, one per lane, each by its own agent's summarizer, pausing an agent
/// after a failure. Driven by the store's transcript reads, so it adds no
/// timer of its own.
@MainActor
final class LaneSummaries {
    struct Job: Sendable {
        var agent: String
        var source: String
        var digest: TranscriptDigest
    }

    private(set) var entries: [String: LaneSummaryEntry]
    private(set) var pausedUntil: [String: Date] = [:]
    private(set) var running: Set<String> = []
    /// The latest conversation of each lane, kept so a reply that changed
    /// inside the reply interval is summarised once the interval passes.
    private var latest: [String: Job] = [:]
    private var queue: [String] = []
    private let summarizers: [String: any LaneSummarizing]
    private let cache: LaneSummaryCache?
    private let workQueue = DispatchQueue(label: "agentsmate.summaries", qos: .background, attributes: .concurrent)
    private var saveScheduled = false
    var maxConcurrent = SummarySchedule.maxConcurrent
    /// Whether new summaries may start; Low Power Mode holds them.
    var canStart: () -> Bool = { !ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// A lane's new summary.
    var onSummary: ((String, String) -> Void)?
    var now: () -> Date = Date.init

    init(summarizers: [any LaneSummarizing], cache: LaneSummaryCache?) {
        var byAgent: [String: any LaneSummarizing] = [:]
        for summarizer in summarizers { byAgent[summarizer.agent] = summarizer }
        self.summarizers = byAgent
        self.cache = cache
        self.entries = cache?.read() ?? [:]
    }

    func summary(for id: String) -> String? { entries[id]?.summary }

    func canSummarize(agent: String) -> Bool { summarizers[agent] != nil }

    /// Take a lane's latest conversation and queue a summary if one is due.
    func consider(_ id: String, agent: String, source: String, digest: TranscriptDigest) {
        guard summarizers[agent] != nil else { return }
        latest[id] = Job(agent: agent, source: source, digest: digest)
        enqueueIfDue(id)
        pump()
    }

    /// Look again at every lane, for replies whose interval has passed.
    func tick() {
        for id in latest.keys { enqueueIfDue(id) }
        pump()
    }

    /// Forget lanes no longer in the list.
    func retain(_ ids: Set<String>) {
        latest = latest.filter { ids.contains($0.key) }
        queue.removeAll { !ids.contains($0) }
    }

    private func enqueueIfDue(_ id: String) {
        guard let job = latest[id], !running.contains(id), !queue.contains(id),
              LaneSummaryEntry.isDue(entries[id], source: job.source, digest: job.digest, now: now()) else { return }
        queue.append(id)
    }

    private func isPaused(_ agent: String) -> Bool {
        pausedUntil[agent].map { now() < $0 } ?? false
    }

    private func pump() {
        guard canStart() else { return }
        while running.count < maxConcurrent,
              let index = queue.firstIndex(where: { latest[$0].map { !isPaused($0.agent) } ?? false }) {
            let id = queue.remove(at: index)
            guard let job = latest[id], let summarizer = summarizers[job.agent] else { continue }
            running.insert(id)
            workQueue.async { [weak self] in
                let result = Result { try summarizer.summarize(job.digest) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finish(id, job: job, result: result) }
                }
            }
        }
        queue.removeAll { latest[$0] == nil }
    }

    func finish(_ id: String, job: Job, result: Result<String, any Error>) {
        running.remove(id)
        switch result {
        case .success(let summary):
            entries[id] = LaneSummaryEntry(source: job.source, summary: summary,
                                           promptPrint: LaneSummaryEntry.fingerprint(job.digest.prompts.last),
                                           replyPrint: LaneSummaryEntry.fingerprint(job.digest.lastReply),
                                           generatedAt: now())
            onSummary?(id, summary)
            scheduleSave()
        case .failure:
            // Not signed in, a rate limit, no CLI: trying again at once
            // would only fail again.
            pausedUntil[job.agent] = now().addingTimeInterval(SummarySchedule.failurePause)
        }
        pump()
    }

    private func scheduleSave() {
        guard let cache, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                let entries = self.entries
                DispatchQueue.global(qos: .background).async { cache.write(entries) }
            }
        }
    }
}

/// How a sidebar row is laid out.
public enum LaneRowStyle: String, Sendable, CaseIterable {
    /// The lane's name, then its status; the summary takes the status line
    /// while the agent is not working.
    case standard
    /// The summary first, at all times, with the lane's name in semibold
    /// beneath it. A lane with no summary yet shows as in ``standard``.
    case summaryFirst
}
