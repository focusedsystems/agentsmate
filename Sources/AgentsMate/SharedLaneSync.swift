import AppKit

/// Keeps a store's lanes in step with the hub's shared list: at launch, when
/// the app becomes active, every 30 seconds while it is, and a second after
/// any change here. Each sync reads the hub's list, merges this Mac's lanes
/// into it, writes it back when that changed anything, and applies the
/// result to the sidebar. The list as last synced is cached, so a launch
/// with the hub out of reach still shows the lanes it last knew of, on top
/// of this Mac's own restore.
@MainActor
final class SharedLaneSync {
    static let debounce: TimeInterval = 1
    static let activeInterval: TimeInterval = 30
    /// How often it syncs while the app is not frontmost (an app the installer
    /// reopened hidden still has to mirror its rows).
    static let idleInterval: TimeInterval = 300

    private weak var store: AgentLaneStore?
    let transport: any SharedLaneTransport
    let cacheFile: URL?
    let restores: Bool
    /// The list as last synced, or as cached from an earlier launch.
    private(set) var base: SharedLaneList
    private var hasCache: Bool
    /// Lanes closed here that the hub has not heard about yet.
    private(set) var pendingClosed: [String: Date] = [:]
    /// What this Mac's lanes were at the last sync, to skip syncs that
    /// would change nothing.
    private var lastLocal: [SharedLaneList.Lane]?
    private(set) var started = false
    private(set) var appliedOnce = false
    private var running = false
    private var rerun = false
    private var waiting: [() -> Void] = []
    private var debounceTimer: Timer?
    private var activeTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Why the last sync failed, or nil after one that worked.
    private(set) var lastError: String?
    private let io = DispatchQueue(label: "agentsmate.shared-lanes", qos: .utility)

    init(store: AgentLaneStore, transport: any SharedLaneTransport, cacheFile: URL?, restores: Bool = true) {
        self.restores = restores
        self.store = store
        self.transport = transport
        self.cacheFile = cacheFile
        if let cacheFile, let data = try? Data(contentsOf: cacheFile), let cached = try? SharedLaneList.decode(data) {
            base = cached
            hasCache = true
        } else {
            base = SharedLaneList()
            hasCache = false
        }
    }

    /// Begin syncing, once the app has restored what it reopens at launch.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sync()
                self?.startActiveTimer(interval: Self.activeInterval)
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startActiveTimer(interval: Self.idleInterval) }
        })
        startActiveTimer(interval: NSApp?.isActive == true ? Self.activeInterval : Self.idleInterval)
        sync()
    }

    /// Something about the lanes changed here: sync a second later.
    func localChanged() {
        guard started else { return }
        debounceTimer?.invalidate()
        let timer = Timer(timeInterval: Self.debounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.debounceTimer = nil
                self?.syncIfChanged()
            }
        }
        timer.tolerance = Self.debounce * CadenceTimer.toleranceFraction
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    /// The person closed a lane here.
    func closed(_ id: String) {
        pendingClosed[id] = SharedLaneList.now()
    }

    private func syncIfChanged() {
        guard let store else { return }
        if pendingClosed.isEmpty, let lastLocal, lastLocal == store.sharedLaneEntries() { return }
        sync()
    }

    /// Sync every `interval` seconds, in place of any timer already running.
    private func startActiveTimer(interval: TimeInterval) {
        activeTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        timer.tolerance = interval * CadenceTimer.toleranceFraction
        RunLoop.main.add(timer, forMode: .common)
        activeTimer = timer
    }

    /// Sync now, or right after the sync already running. `done` is called
    /// on the main actor once it has been applied.
    func sync(done: (() -> Void)? = nil) {
        if let done { waiting.append(done) }
        guard let store else { return }
        if running {
            rerun = true
            return
        }
        running = true
        debounceTimer?.invalidate()
        debounceTimer = nil
        let local = store.sharedLaneEntries()
        let closing = pendingClosed.map { SharedLaneList.Closed(id: $0.key, at: $0.value) }
        let base = self.base
        let transport = self.transport
        let restores = self.restores
        let edited = store.layoutEditedAt
        io.async {
            let outcome = Result { () throws -> SharedLaneList in
                let remote = try transport.read().map(SharedLaneList.decode) ?? SharedLaneList()
                let merged = SharedLaneList.reconcile(local: local, base: base, remote: remote, closing: closing,
                                                        restores: restores, edited: edited)
                if merged != remote { try transport.write(merged.encoded()) }
                return merged
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(outcome, local: local, closing: closing) }
            }
        }
    }

    private func finish(_ outcome: Result<SharedLaneList, Error>, local: [SharedLaneList.Lane],
                        closing: [SharedLaneList.Closed]) {
        running = false
        switch outcome {
        case .success(let merged):
            lastError = nil
            base = merged
            hasCache = true
            saveCache(merged)
            for close in closing where pendingClosed[close.id] == close.at { pendingClosed.removeValue(forKey: close.id) }
            store?.applyShared(merged, captured: local, skipping: Set(pendingClosed.keys))
            appliedOnce = true
        case .failure(let error):
            lastError = "\(error)"
            // The hub is out of reach: show the lanes last known, once.
            if !appliedOnce, hasCache {
                store?.applyShared(base, captured: local, skipping: Set(pendingClosed.keys))
                appliedOnce = true
            }
        }
        lastLocal = store?.sharedLaneEntries()
        if rerun {
            rerun = false
            sync()
            return
        }
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0() }
    }

    private func saveCache(_ list: SharedLaneList) {
        guard let cacheFile, let data = try? list.encoded() else { return }
        io.async {
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
    }

    /// Wait for cache writes already queued, for tests.
    func flush() { io.sync {} }
}
