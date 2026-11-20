import Foundation

/// When the store reads row metadata, and what it may reuse.
enum RowMetadataSchedule {
    /// Every lane's pull request and ports.
    static let fullSweep: TimeInterval = 600
    /// The selected lane and the split, read more often than the rest.
    static let visibleSweep: TimeInterval = 60
    /// How long an open or draft pull request answer is reused.
    static let pullRequestCacheAge: TimeInterval = 300

    struct CachedPullRequest: Sendable, Equatable {
        var date: Date
        var value: LaneRowMetadata.PullRequest?
    }

    static func cacheKey(directory: String, branch: String) -> String { directory + "#" + branch }

    /// Whether to ask `gh` again. A merged or closed pull request is final
    /// for its branch; anything else is reused for five minutes.
    static func needsFetch(_ cached: CachedPullRequest?, now: Date) -> Bool {
        guard let cached else { return true }
        if let state = cached.value?.state, state == .merged || state == .closed { return false }
        return now.timeIntervalSince(cached.date) >= pullRequestCacheAge
    }
}

/// Which metadata sweeps are running. A full sweep asked for while one runs
/// is skipped; lanes asked for while a lane sweep runs are read next.
struct RowMetadataSweeps {
    enum Kind: Hashable, Sendable { case all, lanes }

    private(set) var running: Set<Kind> = []
    private(set) var queued: [String] = []

    /// Whether the sweep may start now.
    mutating func begin(_ kind: Kind, lanes: [String]) -> Bool {
        guard !running.contains(kind) else {
            if kind == .lanes { for id in lanes where !queued.contains(id) { queued.append(id) } }
            return false
        }
        running.insert(kind)
        return true
    }

    /// End a sweep; returns the lanes to read next, if any.
    mutating func end(_ kind: Kind) -> [String] {
        running.remove(kind)
        guard kind == .lanes else { return [] }
        defer { queued = [] }
        return queued
    }
}

/// One file-system watcher per repository HEAD file, shared by every lane
/// in that repository. Git replaces HEAD by renaming a new file over it, so
/// a delete or rename re-opens the path.
@MainActor
final class HeadWatchers {
    private var watchers: [URL: HeadFileWatcher] = [:]
    private var headByLane: [String: URL] = [:]
    private let onChange: (URL) -> Void

    init(onChange: @escaping (URL) -> Void) { self.onChange = onChange }

    /// Watch exactly these lanes' HEAD files; a lane left out is not in a repository.
    func watch(_ heads: [String: URL]) {
        headByLane = heads
        let wanted = Set(headByLane.values)
        for (url, watcher) in watchers where !wanted.contains(url) {
            watcher.cancel()
            watchers.removeValue(forKey: url)
        }
        for url in wanted {
            if let existing = watchers[url], existing.isArmed { continue }
            watchers[url]?.cancel()
            watchers[url] = HeadFileWatcher(url: url) { [weak self] in self?.onChange(url) }
        }
    }

    func head(of lane: String) -> URL? { headByLane[lane] }

    func lanes(watching head: URL) -> [String] {
        headByLane.filter { $0.value == head }.map(\.key).sorted()
    }

    var watchedFiles: Set<URL> { Set(watchers.keys) }
}

@MainActor
final class HeadFileWatcher {
    let url: URL
    private var source: DispatchSourceFileSystemObject?
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    var isArmed: Bool { source != nil }

    private func arm() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let replaced = (source?.data ?? []).contains(.delete) || (source?.data ?? []).contains(.rename)
            MainActor.assumeIsolated {
                guard let self else { return }
                if replaced {
                    self.cancel()
                    self.arm()
                }
                self.onChange()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }
}
