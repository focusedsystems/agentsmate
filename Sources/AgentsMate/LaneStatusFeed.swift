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
/// Reads the shared ``LaneStatusDirectory``, re-reading when the folder
/// changes and on a slow timer in case a change notice is missed, and merges
/// in any extra ``LaneStatusSource``s. Where two disagree about a lane, the
/// newer record wins.
@MainActor
public final class LaneStatusFeed: ObservableObject {
    @Published public private(set) var records: [LaneStatus] = []
    /// The running sessions the presence sources list.
    @Published public private(set) var presence: [LanePresence] = []
    public let presenceSources: [any LanePresenceSource]
    public let directory: LaneStatusDirectory
    public let sources: [any LaneStatusSource]
    public let pollInterval: TimeInterval

    private var hookRecords: [LaneStatus] = []
    private var sourceRecords: [LaneStatus] = []
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var polling = false

    public init(directory: LaneStatusDirectory = .default(), sources: [any LaneStatusSource] = [],
                presenceSources: [any LanePresenceSource] = [], pollInterval: TimeInterval = 5) {
        self.directory = directory
        self.sources = sources
        self.presenceSources = presenceSources
        self.pollInterval = pollInterval
    }

    public func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        reload()
        let fd = open(directory.url.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
                self?.poll()
            }
        }
        poll()
    }

    public func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
    }

    public func reload() {
        hookRecords = directory.readAll()
        publish()
    }

    private func poll() {
        guard !sources.isEmpty || !presenceSources.isEmpty, !polling else { return }
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
