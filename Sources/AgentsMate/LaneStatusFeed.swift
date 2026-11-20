import Foundation
import Combine
import AgentsMateStatus

/// Somewhere other than the hook folder that reports lane status, such as a
/// daemon's own session list. Polled on the feed's timer.
public protocol LaneStatusSource: Sendable {
    func records() async -> [LaneStatus]
}

/// The lane status records, kept current as hooks write them.
///
/// Reads the shared ``LaneStatusDirectory``, re-reading when the folder or
/// its notes change and on a slow timer in case a change notice is missed,
/// and merges in any extra ``LaneStatusSource``s. Where two disagree about a
/// lane, the newer record wins. Both timers have a tolerance and stretch
/// while the app is in the background, in Low Power Mode or running hot.
@MainActor
public final class LaneStatusFeed: ObservableObject {
    @Published public private(set) var records: [LaneStatus] = []
    /// What scripts in the lanes say about their work, by lane.
    @Published public private(set) var notes: [String: LaneNote] = [:]
    /// The running sessions the presence sources list.
    @Published public private(set) var presence: [LanePresence] = []
    public let presenceSources: [any LanePresenceSource]
    public let directory: LaneStatusDirectory
    public let sources: [any LaneStatusSource]
    /// How often the hook folder is re-read regardless of change notices: a
    /// safety net, since the folder watcher sees every write.
    public let pollInterval: TimeInterval
    /// How often the extra sources and presence sources are asked. A source
    /// such as a daemon's session list or `tmux list-sessions` starts a
    /// process each time, so it runs on its own clock.
    public let sourceInterval: TimeInterval

    private var hookRecords: [LaneStatus] = []
    private var sourceRecords: [LaneStatus] = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var reloadTimer: CadenceTimer?
    private var sourceTimer: CadenceTimer?
    private var polling = false

    public init(directory: LaneStatusDirectory = .default(), sources: [any LaneStatusSource] = [],
                presenceSources: [any LanePresenceSource] = [], pollInterval: TimeInterval = 60,
                sourceInterval: TimeInterval = 30) {
        self.directory = directory
        self.sources = sources
        self.presenceSources = presenceSources
        self.pollInterval = pollInterval
        self.sourceInterval = sourceInterval
    }

    public func start() {
        guard reloadTimer == nil else { return }
        try? FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: directory.notesURL, withIntermediateDirectories: true)
        reload()
        for url in [directory.url, directory.notesURL] {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
        reloadTimer = CadenceTimer(interval: pollInterval) { [weak self] in self?.reload() }
        if !sources.isEmpty || !presenceSources.isEmpty {
            sourceTimer = CadenceTimer(interval: sourceInterval, fireNow: true) { [weak self] in self?.poll() }
        }
    }

    public func stop() {
        for source in watchers { source.cancel() }
        watchers = []
        reloadTimer?.invalidate()
        reloadTimer = nil
        sourceTimer?.invalidate()
        sourceTimer = nil
    }

    public func reload() {
        hookRecords = directory.readAll()
        let fresh = Dictionary(directory.readNotes().map { ($0.lane, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
        if fresh != notes { notes = fresh }
        publish()
    }

    private func poll() {
        // A source still answering the last ask is not asked again.
        guard !polling else { return }
        polling = true
        let sources = sources, presenceSources = presenceSources
        Task { [weak self] in
            var all: [LaneStatus] = []
            for source in sources { all += await source.records() }
            var running: [LanePresence] = []
            for source in presenceSources { running += await source.sessions() }
            self?.sourceRecords = all
            if self?.presence != running { self?.presence = running }
            self?.polling = false
            self?.publish()
        }
    }

    private func publish() {
        let merged = (hookRecords + sourceRecords).sorted { $0.updatedAt > $1.updatedAt }
        if merged != records { records = merged }
    }
}
