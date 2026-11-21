import AppKit
import UserNotifications
import Combine
import AgentsMateStatus

/// Every lane, the terminal behind each, and which one is showing. Owned by
/// the app rather than a window, so terminals outlive the view that shows them.
@MainActor
public final class AgentLaneStore: ObservableObject {
    /// What the app injects: how terminals look and what they are told.
    public struct Configuration {
        /// `TERM_PROGRAM` for every lane.
        public var termProgram: String
        /// Added to every lane's environment.
        public var environment: [String: String]
        /// The terminals' text size before the person's ⌘+ / ⌘- changes.
        /// Apps with a text size setting pass it; the default follows the
        /// system's.
        public var baseFontSize: CGFloat
        public var scrollback: Int
        /// The shortcuts a focused terminal answers itself.
        public var shortcuts: TerminalShortcut.Set
        /// Prefix for the saved filters, selection and text size.
        public var defaultsPrefix: String
        /// Mark lanes whose session runs with no terminal attached anywhere.
        /// Off for an app whose lanes are kept running on purpose.
        public var highlightsOrphans: Bool
        /// Closing a lane the person opened also stops its session, as
        /// closing a workspace in a terminal multiplexer does. Off by
        /// default: a lane attaches a session that outlives the app, so
        /// closing its row only ends the terminal here, the session shows
        /// in the Detached section, and Stop is what ends it.
        public var closeStopsLane: Bool
        /// Where each lane's `$AGENTSMATE_SESSION` file lives, for agents to
        /// label their row. Nil turns the files off.
        public var sessionFileDirectory: URL?
        /// ⌃Tab and ⇧⌘[ ] skip lanes that have not been started yet.
        public var cycleSkipsUnstarted: Bool
        /// The workspaces file. Nil turns workspaces and restore off.
        public var workspaceFile: URL?
        /// Show each lane's git branch, pull request and listening ports.
        public var showsRowMetadata: Bool
        /// Post a macOS notification when a lane wants the person while
        /// they are looking elsewhere, and badge the Dock with the count.
        public var notifies: Bool
        /// The Claude model that writes one-line lane summaries, such as
        /// "haiku". Nil turns summaries off. Each lane is summarised by its
        /// own agent: Claude lanes by this model, Codex lanes by
        /// ``codexSummaryModel``, each a short call on the person's own
        /// account. The person can still turn them off in Settings.
        public var summaryModel: String?
        /// The Codex model for Codex lanes' summaries; nil is Codex's default,
        /// at low reasoning effort.
        public var codexSummaryModel: String?
        /// Summarizers that replace the built-in one for their agent, or add
        /// one for another agent. They run only while ``summaryModel`` is set.
        public var summarizers: [any LaneSummarizing]
        /// Where summaries are kept between launches; nil keeps them in
        /// memory only.
        public var summaryCacheFile: URL?
        /// How each sidebar row is laid out.
        public var rowStyle: LaneRowStyle

        /// `~/Library/Caches/<bundle id>/agent-summaries.json`, or the process
        /// name in place of the bundle id when there is none.
        public static var defaultSummaryCacheFile: URL { LaneSummaryCache.defaultURL() }
        /// Where to read the agents' usage limits; the lane sidebar shows a
        /// meter at its foot when there are any.
        public var usageSources: [any AgentUsageSource]
        /// What Reopen As offers, in order. Each names a registered backend;
        /// a choice's ``LaneReopenChoice/kind`` gives it that kind's shortcut.
        public var reopenChoices: [LaneReopenChoice]
        /// The id of the app's inbox window scene (a `Window` holding
        /// ``AgentInboxView``). Set, the sidebar's foot gets an inbox button
        /// with a badge, and the Agent menu an Agent Inbox item.
        public var inboxWindowID: String?
        /// The id of the app's ``AgentMessageWindow`` scene. Set, Message
        /// Agent opens that window; nil keeps the sidebar's alert.
        public var messageWindowID: String?
        /// Resolvers for pull request links the agents post, asked before
        /// the built-in ``GitHubPullRequestResolver``. Add one for Azure
        /// DevOps or a GitHub Enterprise host here.
        public var pullRequestResolvers: [any PullRequestResolver]
        /// Where each lane's pull request links and their last known state
        /// are kept between launches; nil keeps them in memory only.
        public var pullRequestLedgerFile: URL?
        /// Claude Code's pull request status cache, read once at launch as a
        /// warm start for GitHub links. Nil skips it; a missing file is fine.
        public var pullRequestSeedFile: URL?
        /// At launch and about every ten minutes, ask each backend for its
        /// lane sessions (``LaneBackend/discoverSessions()``) and list the
        /// ones no row attaches in a Detached section.
        public var findsDetachedSessions: Bool
        /// Asks the person for a folder when a section header's + starts a
        /// lane, opening at the folder given (nil for the system's choice),
        /// and returns nil when they cancel. The default is an `NSOpenPanel`
        /// (``AgentLaneStore/chooseFolderWithOpenPanel(startingAt:)``); an
        /// app can offer its own recent folders or repositories instead.
        public var chooseFolder: @MainActor (_ startingAt: URL?) async -> URL?

        /// `~/Library/Caches/<bundle id>/agent-pull-requests.json`.
        public static var defaultPullRequestLedgerFile: URL { PullRequestLedgerCache.defaultURL() }
        /// `gh-pr-status-cache.json` in Claude Code's config folder
        /// (`$CLAUDE_CONFIG_DIR`, else `~/.claude`).
        public static var defaultPullRequestSeedFile: URL { ClaudePullRequestSeed.defaultURL() }

        public init(termProgram: String, environment: [String: String] = [:],
                    baseFontSize: CGFloat = NSFont.systemFontSize,
                    scrollback: Int = 20_000, shortcuts: TerminalShortcut.Set = .fixedLanes,
                    defaultsPrefix: String = "agentsmate.", highlightsOrphans: Bool = false,
                    closeStopsLane: Bool = false,
                    sessionFileDirectory: URL? = FileManager.default.temporaryDirectory
                        .appendingPathComponent("agentsmate-sessions", isDirectory: true),
                    cycleSkipsUnstarted: Bool = false, workspaceFile: URL? = nil,
                    showsRowMetadata: Bool = false, notifies: Bool = false, summaryModel: String? = nil,
                    usageSources: [any AgentUsageSource] = [], reopenChoices: [LaneReopenChoice] = [],
                    codexSummaryModel: String? = nil, summarizers: [any LaneSummarizing] = [],
                    summaryCacheFile: URL? = Configuration.defaultSummaryCacheFile, rowStyle: LaneRowStyle = .standard,
                    inboxWindowID: String? = nil, messageWindowID: String? = nil,
                    pullRequestResolvers: [any PullRequestResolver] = [],
                    pullRequestLedgerFile: URL? = Configuration.defaultPullRequestLedgerFile,
                    pullRequestSeedFile: URL? = Configuration.defaultPullRequestSeedFile,
                    findsDetachedSessions: Bool = true,
                    chooseFolder: @escaping @MainActor (_ startingAt: URL?) async -> URL? = AgentLaneStore.chooseFolderWithOpenPanel) {
            self.findsDetachedSessions = findsDetachedSessions
            self.chooseFolder = chooseFolder
            self.pullRequestResolvers = pullRequestResolvers
            self.pullRequestLedgerFile = pullRequestLedgerFile
            self.pullRequestSeedFile = pullRequestSeedFile
            self.inboxWindowID = inboxWindowID
            self.messageWindowID = messageWindowID
            self.codexSummaryModel = codexSummaryModel
            self.summarizers = summarizers
            self.summaryCacheFile = summaryCacheFile
            self.rowStyle = rowStyle
            self.reopenChoices = reopenChoices
            self.usageSources = usageSources
            self.summaryModel = summaryModel
            self.notifies = notifies
            self.showsRowMetadata = showsRowMetadata
            self.workspaceFile = workspaceFile
            self.sessionFileDirectory = sessionFileDirectory
            self.cycleSkipsUnstarted = cycleSkipsUnstarted
            self.highlightsOrphans = highlightsOrphans
            self.closeStopsLane = closeStopsLane
            self.termProgram = termProgram
            self.environment = environment
            self.baseFontSize = baseFontSize
            self.scrollback = scrollback
            self.shortcuts = shortcuts
            self.defaultsPrefix = defaultsPrefix
        }
    }

    @Published public private(set) var lanes: [AgentLane] = [] {
        didSet { if lanes != oldValue { scheduleRestoreWrite() } }
    }
    @Published public private(set) var sessions: [AgentLane.ID: AgentLaneSession] = [:]
    @Published public var selectedID: AgentLane.ID? {
        didSet {
            if selectedID != oldValue { scheduleRestoreWrite() }
            defaults.set(selectedID, forKey: keys.selectedLane)
            updateShown()
            if selectedID != oldValue { rowMetadataSelectionChanged() }
        }
    }
    /// The lane shown beside the selected one, when split.
    @Published public var splitID: AgentLane.ID? {
        didSet {
            updateShown()
            if splitID != oldValue { rowMetadataSelectionChanged() }
        }
    }
    /// Whether a lane's terminal or the lane list has the keyboard. The
    /// Reopen As keys are the lanes' only then.
    @Published public internal(set) var lanesHaveKeyboard = false
    let keyboard = LaneKeyboardTracker()

    /// Whether the lanes are on screen; set by the view that shows them.
    public var isShowing = false {
        didSet {
            updateShown()
            if isShowing != oldValue { transcriptTimer?.setInterval(TranscriptSchedule.interval(showing: isShowing)) }
        }
    }

    public var configuration: Configuration {
        didSet { if configuration.baseFontSize != oldValue.baseFontSize { applyFont() } }
    }
    /// Points added to the base size with ⌘+ and ⌘-, kept across launches.
    @Published public private(set) var fontOffset: CGFloat = 0
    public static let fontSizeRange: ClosedRange<CGFloat> = 8...36
    public let keys: AgentsModeKeys
    public let statusFeed: LaneStatusFeed?
    /// What ⌘T opens, when the app allows it.
    public var onNewLane: (() -> Void)?
    /// Called just before a lane's process starts, so the app can prepare
    /// it: write a per-lane instructions file, set its environment, or pick
    /// the backend a lane that follows a default should run. The lane it
    /// returns is the one started.
    public var willStartLane: ((AgentLane) -> AgentLane)?

    /// What closing a lane does: take the row away, or end its terminal and
    /// keep the row so it can start again (an app's standing rows).
    public enum CloseDecision: Sendable { case remove, keepRow }
    /// Asked when a lane is closed, with whether its terminal is attached.
    public var willCloseLane: ((AgentLane, Bool) -> CloseDecision)?
    /// Told after a lane is closed, with what happened to it.
    public var didCloseLane: ((AgentLane, CloseDecision) -> Void)?

    /// The file the agent in a lane may write its row label to
    /// (`$AGENTSMATE_SESSION`), or nil when session files are off.
    public func sessionFile(for id: AgentLane.ID) -> URL? {
        configuration.sessionFileDirectory?.appendingPathComponent(AgentLaneSession.fileName(id) + ".json")
    }

    /// Start a lane's process, letting the app prepare it first.
    func start(_ session: AgentLaneSession) {
        if !session.isAttached, let willStartLane, let index = lanes.firstIndex(where: { $0.id == session.id }) {
            let prepared = willStartLane(lanes[index])
            if prepared != lanes[index] {
                lanes[index] = prepared
                session.update(lane: prepared)
                if let backend = backends[prepared.backendID] { session.update(backend: backend) }
            }
        }
        session.start(configuration: configuration, font: font)
    }

    /// The person's keyboard shortcuts for the lanes' commands.
    @Published public var shortcuts = LaneShortcutBindings() {
        didSet {
            guard shortcuts != oldValue, let data = try? JSONEncoder().encode(shortcuts) else { return }
            defaults.set(data, forKey: keys.shortcuts)
        }
    }

    /// Sections, pins, order and sort, as the person left them.
    @Published public var layout = LaneLayout() {
        didSet {
            guard layout != oldValue, let data = try? JSONEncoder().encode(layout) else { return }
            defaults.set(data, forKey: keys.layout)
            scheduleRestoreWrite()
        }
    }

    private var backends: [String: any LaneBackend] = [:]
    private let defaults: UserDefaults
    private var feedSubscription: AnyCancellable?
    private var presenceSubscription: AnyCancellable?
    private var notesSubscription: AnyCancellable?

    public init(configuration: Configuration, backends: [any LaneBackend],
                statusFeed: LaneStatusFeed? = LaneStatusFeed(), defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.keys = AgentsModeKeys(prefix: configuration.defaultsPrefix)
        self.statusFeed = statusFeed
        self.defaults = defaults
        for backend in backends { self.backends[backend.id] = backend }
        self.selectedID = defaults.string(forKey: keys.selectedLane)
        keyboard.onChange = { [weak self] in self?.updateLanesHaveKeyboard() }
        self.fontOffset = CGFloat(defaults.double(forKey: keys.fontOffset))
        if let data = defaults.data(forKey: keys.shortcuts),
           let saved = try? JSONDecoder().decode(LaneShortcutBindings.self, from: data) {
            self.shortcuts = saved
        }
        if let data = defaults.data(forKey: keys.layout),
           let saved = try? JSONDecoder().decode(LaneLayout.self, from: data) {
            self.layout = saved
        }
        feedSubscription = statusFeed?.$records.sink { [weak self] records in
            MainActor.assumeIsolated { self?.apply(records) }
        }
        presenceSubscription = statusFeed?.$presence.sink { [weak self] presence in
            MainActor.assumeIsolated { self?.apply(presence: presence) }
        }
        notesSubscription = statusFeed?.$notes.sink { [weak self] notes in
            MainActor.assumeIsolated { self?.apply(notes: notes) }
        }
        statusFeed?.start()
        if statusFeed != nil { startTranscripts() }
        if configuration.showsRowMetadata { startRowMetadata() }
        if configuration.notifies { notifier = LaneNotifier(store: self) }
        startSummaries()
        startPullRequestLedger()
        if !configuration.usageSources.isEmpty { usage = AgentUsageModel(sources: configuration.usageSources) }
        if configuration.findsDetachedSessions { startDiscovery() }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // Terminals ending as the app quits are not the person closing
            // them; the app's own saveRestore() records what was open.
            MainActor.assumeIsolated { self?.freezeRestore() }
        }
    }

    private var terminationObserver: NSObjectProtocol?

    // MARK: History

    @Published public private(set) var history: [AgentLane.ID] = []
    @Published public private(set) var historyIndex = -1
    private var navigatingHistory = false

    private func recordVisit(_ id: AgentLane.ID) {
        guard !navigatingHistory, history.indices.contains(historyIndex) ? history[historyIndex] != id : true else { return }
        history = Array(history.prefix(historyIndex + 1)) + [id]
        if history.count > 100 { history.removeFirst(history.count - 100) }
        historyIndex = history.count - 1
    }

    public var canGoBack: Bool { previousInHistory(by: -1) != nil }
    public var canGoForward: Bool { previousInHistory(by: 1) != nil }

    private func previousInHistory(by step: Int) -> Int? {
        var index = historyIndex + step
        while history.indices.contains(index) {
            if sessions[history[index]] != nil { return index }
            index += step
        }
        return nil
    }

    /// Back to the lane shown before this one, skipping lanes since closed.
    public func goBack() { go(by: -1) }
    public func goForward() { go(by: 1) }

    private func go(by step: Int) {
        guard let index = previousInHistory(by: step) else { return }
        historyIndex = index
        navigatingHistory = true
        open(history[index])
        navigatingHistory = false
    }

    // MARK: Palette

    /// Whether Go to Lane… is showing.
    @Published public var paletteVisible = false

    /// Lanes matching `query`, best first: every word must appear in the
    /// name, folder, branch, section or summary; a match at the start of the name
    /// ranks first, then recently active lanes.
    public func paletteResults(_ query: String) -> [AgentLane] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let ordered = displayOrder
        guard !words.isEmpty else { return ordered }
        func haystack(_ lane: AgentLane) -> String {
            let session = sessions[lane.id]
            return [session?.title ?? lane.title, lane.path, session?.rowMetadata.branch ?? "", layout.section(of: lane) ?? "",
                    session?.summary ?? ""]
                .joined(separator: " ").lowercased()
        }
        let hits = ordered.filter { lane in let text = haystack(lane); return words.allSatisfy(text.contains) }
        return hits.sorted { a, b in
            let ta = (sessions[a.id]?.title ?? a.title).lowercased().hasPrefix(words[0])
            let tb = (sessions[b.id]?.title ?? b.title).lowercased().hasPrefix(words[0])
            if ta != tb { return ta }
            return (sessions[a.id]?.lastActivity ?? .distantPast) > (sessions[b.id]?.lastActivity ?? .distantPast)
        }
    }

    // MARK: Attention

    /// The lane Message Agent writes to; the message window's picker
    /// shows and changes it.
    @Published public var messageTarget: AgentLane.ID?
    /// The lane the sidebar's message alert is open for, when the app has
    /// no message window.
    @Published var messageAlertTarget: AgentLane.ID?
    /// Opens a pull request link from the inbox. Nil opens it in the
    /// default browser.
    public var onOpenPullRequest: ((URL) -> Void)?
    /// Answers a link ⌘-clicked in a lane's terminal (an OSC 8 hyperlink
    /// or a plain http or https URL), with the lane it was clicked in.
    /// Returns whether the app handled it; when it returns false or is nil,
    /// http, https and mailto links open in the default app and other
    /// schemes, `file:` among them, are dropped.
    public var onOpenLink: ((URL, AgentLane.ID) -> Bool)?

    private var notifier: LaneNotifier?
    /// The agents' usage limits, when the app gave usage sources.
    public private(set) var usage: AgentUsageModel?

    /// The lanes that want the person and that they have not looked at.
    public var unreadLanes: [AgentLane] {
        displayOrder.filter { sessions[$0.id]?.needsAttention == true }
    }

    /// Show the first lane waiting for the person, if any.
    @discardableResult
    public func jumpToUnread() -> Bool {
        guard let lane = unreadLanes.first else { return false }
        open(lane.id)
        return true
    }

    /// Show a lane a notification named. For an app that keeps its own
    /// notification delegate and forwards AgentsMate's responses.
    public func handleNotification(_ response: UNNotificationResponse) {
        if let id = response.notification.request.content.userInfo["agentsmate.lane"] as? String { showFromNotification(id) }
    }

    func showFromNotification(_ id: AgentLane.ID) {
        NSApp.activate(ignoringOtherApps: true)
        open(id)
        onShowLane?(id)
    }

    /// Called when a notification or Jump to Unread brings a lane forward,
    /// so the app can switch to its lanes (Agents mode, the dock).
    public var onShowLane: ((AgentLane.ID) -> Void)?

    private func laneWantsAttention(_ session: AgentLaneSession) {
        guard configuration.notifies else { return }
        let lookingAtIt = session.isShown && NSApp.isActive
        if !lookingAtIt { notifier?.post(for: session) }
        updateBadge()
    }

    func updateBadge() {
        guard configuration.notifies, LaneNotifier.isAvailable else { return }
        let count = unreadLanes.count
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: Row metadata

    private var fullSweepTimer: CadenceTimer?
    private var visibleSweepTimer: CadenceTimer?
    private var selectionRefresh: Timer?
    private var pullRequestCache: [String: RowMetadataSchedule.CachedPullRequest] = [:]
    private var sweeps = RowMetadataSweeps()
    private let gh = LaneRowMetadataReader.locateGH()
    private lazy var headWatchers = HeadWatchers { [weak self] head in self?.headChanged(head) }

    private func startRowMetadata() {
        syncHeadWatchers()
        refreshRowMetadata()
        fullSweepTimer = CadenceTimer(interval: RowMetadataSchedule.fullSweep) { [weak self] in
            self?.refreshRowMetadata()
        }
        visibleSweepTimer = CadenceTimer(interval: RowMetadataSchedule.visibleSweep) { [weak self] in
            self?.refreshVisibleRowMetadata()
        }
    }

    /// Read every lane's branch, ports and pull request, off the main
    /// thread. Skipped while the last full read is still going. Branches
    /// also follow each repository's HEAD file as it changes, and the
    /// selected lanes are read more often than the rest.
    public func refreshRowMetadata() {
        // Detached rows are read once someone reattaches or adopts them.
        sweep(.all, lanes: lanes.compactMap { detachedIDs.contains($0.id) && sessions[$0.id]?.isAttached != true ? nil : $0.id })
    }

    /// The lanes the person is looking at: the selected one and the split.
    private var visibleLaneIDs: [AgentLane.ID] {
        [selectedID, splitID].compactMap { $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private func refreshVisibleRowMetadata() {
        let ids = visibleLaneIDs
        if !ids.isEmpty { sweep(.lanes, lanes: ids) }
    }

    /// The selection moved: read its row soon, once rapid cycling settles.
    private func rowMetadataSelectionChanged() {
        guard configuration.showsRowMetadata else { return }
        selectionRefresh?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleRowMetadata() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        selectionRefresh = timer
    }

    private func sweep(_ kind: RowMetadataSweeps.Kind, lanes ids: [AgentLane.ID]) {
        guard configuration.showsRowMetadata, sweeps.begin(kind, lanes: ids) else { return }
        syncHeadWatchers()
        let jobs = ids.compactMap { id -> (String, String, pid_t?)? in
            guard let session = sessions[id] else { return nil }
            return (id, session.isStarted ? session.currentDirectory : session.lane.path, session.shellPID)
        }
        let cache = pullRequestCache, gh = gh, ledger = pullRequestLedger?.state
        // A dispatch queue rather than a task: helpers block while they wait
        // for one of the two process slots.
        DispatchQueue.global(qos: .background).async { [weak self] in
            var results: [String: LaneRowMetadata] = [:]
            var fresh: [String: RowMetadataSchedule.CachedPullRequest] = [:]
            for (id, directory, pid) in jobs {
                var meta = LaneRowMetadata()
                meta.branch = LaneRowMetadataReader.branch(in: directory)
                if let pid { meta.ports = LaneRowMetadataReader.listeningPorts(pids: LaneRowMetadataReader.processTree(pid)) }
                if let branch = meta.branch, let ledger,
                   let known = RowMetadataSchedule.ledgerPullRequest(ledger, lane: id, branch: branch, directory: directory) {
                    // The ledger already tracks this branch's pull request
                    // and rechecks it itself, so `gh` is not asked again.
                    meta.pullRequest = known
                } else if let branch = meta.branch {
                    let key = RowMetadataSchedule.cacheKey(directory: directory, branch: branch)
                    let hit = fresh[key] ?? cache[key]
                    if let hit, !RowMetadataSchedule.needsFetch(hit, now: Date()) {
                        meta.pullRequest = hit.value
                    } else {
                        let value = LaneRowMetadataReader.pullRequest(branch: branch, in: directory, gh: gh)
                        fresh[key] = .init(date: Date(), value: value)
                        meta.pullRequest = value
                    }
                }
                results[id] = meta
            }
            let found = results, cached = fresh
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (id, meta) in found where self.sessions[id]?.rowMetadata != meta { self.sessions[id]?.rowMetadata = meta }
                self.pullRequestCache.merge(cached) { _, new in new }
                let next = self.sweeps.end(kind)
                if !next.isEmpty { self.sweep(.lanes, lanes: next) }
            }
        }
    }

    /// Watch the HEAD file of every lane's repository.
    private func syncHeadWatchers() {
        guard configuration.showsRowMetadata else { return }
        var heads: [AgentLane.ID: URL] = [:]
        for (id, session) in sessions {
            let directory = session.isStarted ? session.currentDirectory : session.lane.path
            heads[id] = LaneRowMetadataReader.headFile(for: directory)
        }
        headWatchers.watch(heads)
    }

    private func laneDirectoryChanged(_ session: AgentLaneSession) {
        guard configuration.showsRowMetadata else { return }
        syncHeadWatchers()
        if let head = headWatchers.head(of: session.id) { headChanged(head) } else { branchChanged(session.id, to: nil) }
    }

    /// A HEAD file changed: update the branch of every lane in that
    /// repository, and look up a pull request for a new branch.
    private func headChanged(_ head: URL) {
        let branch = LaneRowMetadataReader.branch(headFile: head)
        for id in headWatchers.lanes(watching: head) { branchChanged(id, to: branch) }
    }

    private func branchChanged(_ id: AgentLane.ID, to branch: String?) {
        guard let session = sessions[id], session.rowMetadata.branch != branch else { return }
        var meta = session.rowMetadata
        meta.branch = branch
        meta.pullRequest = nil
        var fetch = false
        if let branch {
            let directory = session.isStarted ? session.currentDirectory : session.lane.path
            let hit = pullRequestCache[RowMetadataSchedule.cacheKey(directory: directory, branch: branch)]
            if let hit, !RowMetadataSchedule.needsFetch(hit, now: Date()) { meta.pullRequest = hit.value } else { fetch = true }
        }
        session.rowMetadata = meta
        if fetch { sweep(.lanes, lanes: [id]) }
    }

    /// Add a backend, or replace one with the same id. Lanes already
    /// attached keep running; the new settings apply when each is next
    /// attached.
    public func register(_ backend: any LaneBackend) {
        backends[backend.id] = backend
        for session in sessions.values where session.lane.backendID == backend.id {
            session.update(backend: backend)
        }
        apply(statusFeed?.records ?? [])
        if discoveryTimer != nil { sweepSoon() }
    }

    public func backend(id: String) -> (any LaneBackend)? { backends[id] }

    public var selected: AgentLaneSession? { selectedID.flatMap { sessions[$0] } }
    public var split: AgentLaneSession? { splitID.flatMap { sessions[$0] } }
    public func session(for lane: AgentLane) -> AgentLaneSession? { sessions[lane.id] }

    /// Replace the app's fixed lanes. Lanes the person opened stay after
    /// them; a fixed lane that disappears is detached; terminals are kept.
    /// A fixed lane the person reopened as another agent keeps that agent.
    public func sync(lanes appLanes: [AgentLane]) {
        let overrides = backendOverrides
        let fixed = appLanes.map { lane -> AgentLane in
            guard let backendID = overrides[lane.id], backends[backendID] != nil else { return lane }
            var lane = lane
            lane.backendID = backendID
            return lane
        }
        let opened = lanes.filter { ($0.isClosable || detachedIDs.contains($0.id)) && !fixed.map(\.id).contains($0.id) }
        let newLanes = fixed + opened
        guard newLanes != lanes else { return }
        let ids = Set(newLanes.map(\.id))
        for (id, session) in sessions where !ids.contains(id) {
            session.detach()
            sessions.removeValue(forKey: id)
        }
        lanes = newLanes
        for lane in newLanes { makeSession(for: lane) }
        if splitID.map({ !ids.contains($0) }) ?? false { splitID = nil }
        if selectedID.map({ !ids.contains($0) }) ?? true { selectedID = newLanes.first?.id }
        apply(statusFeed?.records ?? [])
        reconcileDetached()
    }

    /// Add a lane the person opened, and open it.
    @discardableResult
    public func add(_ lane: AgentLane, focus: Bool = true, open shouldOpen: Bool = true,
                    after anchor: AgentLane.ID? = nil) -> AgentLaneSession? {
        if sessions[lane.id] == nil {
            if let anchor, let index = lanes.firstIndex(where: { $0.id == anchor }) {
                lanes.insert(lane, at: index + 1)
                let ordered = layout.orderedIDs(lanes)
                if let at = ordered.firstIndex(of: anchor), at + 1 < ordered.count, ordered[at + 1] != lane.id {
                    layout.moveLane(lane.id, before: ordered[at + 1], lanes: lanes)
                }
            } else {
                lanes.append(lane)
            }
            makeSession(for: lane)
            apply(statusFeed?.records ?? [])
            if !detachedIDs.contains(lane.id) { reconcileDetached() }
        }
        // A lane added without opening waits as a bookmark until first shown.
        if shouldOpen { open(lane.id, focus: focus) }
        return sessions[lane.id]
    }

    // MARK: Workspaces and restore

    /// The workspaces file as last read; re-read with ``reloadWorkspaces()``.
    @Published public private(set) var workspaces = LaneWorkspaceFile()
    @Published public private(set) var workspaceError: String?

    public func reloadWorkspaces() {
        guard let url = configuration.workspaceFile else { return }
        do {
            workspaces = try LaneWorkspaceFile.load(url)
            workspaceError = nil
        } catch {
            workspaceError = "The workspaces file could not be read: \(error.localizedDescription)"
        }
    }

    /// Every write of the workspaces file goes through this queue, so the
    /// restore snapshot written in the background and a workspace saved from
    /// a menu never overwrite each other's change.
    private let workspaceIO = DispatchQueue(label: "agentsmate.workspaces", qos: .background)

    private func writeWorkspaces(_ change: (inout LaneWorkspaceFile) -> Void) {
        guard let url = configuration.workspaceFile else { return }
        // A read-modify-write that the person is waiting on: run it now,
        // after any snapshot write already queued.
        let result: Result<LaneWorkspaceFile, Error> = workspaceIO.sync {
            Result {
                var file = try LaneWorkspaceFile.load(url)
                change(&file)
                try file.save(url)
                return file
            }
        }
        switch result {
        case .success(let file):
            workspaces = file
            workspaceError = nil
        case .failure(let error):
            workspaceError = "The workspaces file could not be saved: \(error.localizedDescription)"
        }
    }

    /// The lanes the person opened, with the sections, as a workspace.
    public func snapshot(named name: String, onlyAttached: Bool = false) -> LaneWorkspace {
        workspace(named: name, lanes: displayOrder.filter { $0.isClosable && (!onlyAttached || sessions[$0.id]?.isAttached == true) },
                  marksSelection: false)
    }

    private func workspace(named name: String, lanes opened: [AgentLane], marksSelection: Bool) -> LaneWorkspace {
        let lanes = opened.map { lane in
            LaneWorkspace.Lane(title: layout.names[lane.id],
                               directory: sessions[lane.id]?.currentDirectory ?? lane.directory?.path,
                               backendID: lane.backendID,
                               section: layout.section(of: lane),
                               pinned: layout.pinned.contains(lane.id) ? true : nil,
                               variant: lane.variant, sessionName: lane.sessionName,
                               selected: marksSelection && lane.id == selectedID ? true : nil)
        }
        let used = Set(lanes.compactMap(\.section))
        return LaneWorkspace(name: name, sections: layout.orderedSections(for: self.lanes).filter { used.contains($0) || layout.sections.contains($0) },
                             lanes: lanes)
    }

    public func saveWorkspace(named name: String) {
        let workspace = snapshot(named: name)
        writeWorkspaces { file in
            file.workspaces.removeAll { $0.name == name }
            file.workspaces.append(workspace)
        }
    }

    public func deleteWorkspace(named name: String) {
        writeWorkspaces { file in
            file.workspaces.removeAll { $0.name == name }
            if file.openAtLaunch == name { file.openAtLaunch = nil }
        }
    }

    public func setOpenAtLaunch(_ name: String?) {
        writeWorkspaces { $0.openAtLaunch = name }
    }

    /// Add a workspace's lanes, skipping any already open in the same folder
    /// on the same backend. They wait until shown, apart from the first.
    public func open(workspace: LaneWorkspace, resume: Bool = false) {
        for name in workspace.sections { layout.addSection(name) }
        var first: AgentLane.ID?
        var chosen: AgentLane.ID?
        for saved in workspace.lanes {
            let path = saved.directory.map { ($0 as NSString).expandingTildeInPath }
            let already = lanes.contains { lane in
                guard !detachedIDs.contains(lane.id), lane.backendID == saved.backendID else { return false }
                if let name = saved.sessionName ?? lane.sessionName { return name == lane.sessionName && name == saved.sessionName }
                return lane.variant == saved.variant
                    && path.map { LaneStatusMatch.normalizedPath($0) == LaneStatusMatch.normalizedPath(lane.path) } ?? false
            }
            if already { continue }
            var lane = AgentLane(id: UUID().uuidString, title: saved.sessionName ?? (path as NSString?)?.lastPathComponent ?? "Lane",
                                 directory: path.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                 backendID: saved.backendID, isClosable: true, section: saved.section)
            lane.variant = saved.variant
            lane.sessionName = saved.sessionName
            // A session the restore brings back attaches here, so its
            // Detached row (if the sweep already found it) goes.
            if let name = saved.sessionName,
               let row = lanes.first(where: { detachedIDs.contains($0.id) && $0.backendID == saved.backendID && $0.sessionName == name }),
               sessions[row.id]?.isAttached != true {
                removeDetachedRow(row.id)
            }
            add(lane, focus: false, open: false)
            if resume {
                sessions[lane.id]?.resumeOnStart = true
                restoredPending.insert(lane.id)
            }
            if let title = saved.title { setName(lane.id, to: title) }
            if saved.pinned == true { layout.setPinned(lane.id, true) }
            if first == nil { first = lane.id }
            if saved.selected == true { chosen = lane.id }
        }
        if let pick = chosen ?? first, selected?.lane.isClosable != true { selectedID = pick }
    }

    /// Record the lanes attached now, to reopen at the next launch. Call when
    /// the app quits.
    ///
    /// The snapshot is also written by itself, about two seconds after the
    /// lanes, the selection or what is attached changes, so a crash or a
    /// reboot keeps it; see ``restoreSnapshot()``.
    public func saveRestore() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        let restore = currentRestore()
        writeWorkspaces { $0.restore = restore }
        if workspaceError == nil { lastWrittenRestore = .some(restore) }
    }

    /// What the restore snapshot records: the lanes the person opened that
    /// are attached here, in list order, and those a restore brought back
    /// that have not been shown yet, since they were open too. The selected
    /// one is marked.
    public func restoreSnapshot() -> LaneWorkspace {
        let open = displayOrder.filter { lane in
            guard lane.isClosable, !detachedIDs.contains(lane.id), let session = sessions[lane.id] else { return false }
            return session.isAttached || (!session.isStarted && restoredPending.contains(lane.id))
        }
        return workspace(named: "Last Session", lanes: open, marksSelection: true)
    }

    private func currentRestore() -> LaneWorkspace? {
        let snapshot = restoreSnapshot()
        return snapshot.lanes.isEmpty ? nil : snapshot
    }

    // MARK: Restore snapshot

    /// How long after a change the restore snapshot is written, so a burst
    /// of changes (a restore, cycling through lanes) is one write.
    static let restoreDebounce: TimeInterval = 2
    private var restoreTimer: Timer?
    /// Lanes a restore added that have not been started yet.
    private var restoredPending: Set<AgentLane.ID> = []
    /// Off until the app has decided what to reopen at launch, so lanes set
    /// up before that never overwrite the snapshot it is about to read.
    private(set) var restoreSettled = false
    private var restoreFrozen = false
    private var lastWrittenRestore: LaneWorkspace??

    private func scheduleRestoreWrite() {
        guard restoreSettled, !restoreFrozen, configuration.workspaceFile != nil else { return }
        restoreTimer?.invalidate()
        let timer = Timer(timeInterval: Self.restoreDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeRestoreInBackground() }
        }
        timer.tolerance = Self.restoreDebounce * CadenceTimer.toleranceFraction
        RunLoop.main.add(timer, forMode: .common)
        restoreTimer = timer
    }

    /// Write the snapshot now, off the main thread, if it changed.
    func writeRestoreInBackground() {
        restoreTimer = nil
        guard !restoreFrozen, let url = configuration.workspaceFile else { return }
        let restore = currentRestore()
        if let last = lastWrittenRestore, last == restore { return }
        lastWrittenRestore = .some(restore)
        workspaces.restore = restore
        workspaceIO.async {
            // An unreadable file is left alone rather than replaced.
            guard var file = try? LaneWorkspaceFile.load(url) else { return }
            guard file.restore != restore else { return }
            file.restore = restore
            try? file.save(url)
        }
    }

    /// Whether a snapshot write is waiting out its debounce.
    var restoreWritePending: Bool { restoreTimer != nil }

    /// Wait for any snapshot write already queued, for tests.
    func flushWorkspaceWrites() { workspaceIO.sync {} }

    private func freezeRestore() {
        restoreFrozen = true
        restoreTimer?.invalidate()
        restoreTimer = nil
    }

    /// Bring back the lanes open at the last quit, each resuming its last
    /// conversation when started; or, failing that, the workspace marked to
    /// open at launch. Returns whether anything was added.
    @discardableResult
    public func restoreAtLaunch() -> Bool {
        defer { restoreSettled = true }
        reloadWorkspaces()
        if let restore = workspaces.restore, !restore.lanes.isEmpty {
            open(workspace: restore, resume: true)
            return true
        }
        if let launch = workspaces.launchWorkspace {
            open(workspace: launch)
            return true
        }
        return false
    }

    // MARK: Detached sessions

    /// Rows for sessions a backend found running with no row of their own,
    /// shown in the Detached section. They are not started until the person
    /// reattaches one, are left out of the restore snapshot and workspaces,
    /// and go when their session does. ``adopt(_:into:)`` makes one a lane
    /// of the person's own.
    @Published public private(set) var detachedIDs: Set<AgentLane.ID> = []

    /// Whether a row is in the Detached section.
    public func isDetached(_ id: AgentLane.ID) -> Bool { detachedIDs.contains(id) }

    /// How often backends are asked for their sessions after launch. Each
    /// ask is at most one helper process per backend, one at a time.
    static let discoveryInterval: TimeInterval = 600
    /// How long after launch (or a backend registering) the first ask
    /// waits, so the app's own lanes and the restore are in first.
    static let firstDiscoveryDelay: TimeInterval = 3

    private var discoveryTimer: CadenceTimer?
    private var discoveryKick: Task<Void, Never>?
    private var sweepingSessions = false
    /// Everything the last sweep found, kept so rows added later can claim
    /// their sessions without asking the backends again.
    private var discovered: [DetachedSessions.Found] = []
    /// The agent session ids each row holds, as of the last status update,
    /// so a session a row attaches leaves Detached whatever it is named.
    private var heldSessionIDs: [AgentLane.ID: [String]] = [:]

    private func startDiscovery() {
        discoveryTimer = CadenceTimer(interval: Self.discoveryInterval) { [weak self] in
            self?.sweepForDetachedSessions()
        }
        sweepSoon()
    }

    /// One sweep a moment from now, however many times this is called.
    private func sweepSoon() {
        guard discoveryKick == nil else { return }
        discoveryKick = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstDiscoveryDelay))
            guard let self else { return }
            self.discoveryKick = nil
            self.sweepForDetachedSessions()
        }
    }

    /// Ask every backend for its lane sessions now and update the Detached
    /// section. Skipped while the last sweep is still going.
    public func sweepForDetachedSessions() {
        guard configuration.findsDetachedSessions, !sweepingSessions else { return }
        sweepingSessions = true
        let backends = availableBackends
        Task { @MainActor [weak self] in
            var found: [DetachedSessions.Found] = []
            // One backend at a time, so the sweep holds at most one helper.
            for backend in backends {
                for session in await backend.discoverSessions() {
                    found.append(.init(backendID: backend.id, session: session))
                }
            }
            guard let self else { return }
            self.sweepingSessions = false
            self.discovered = found
            self.reconcileDetached()
        }
    }

    /// Match the last sweep against the rows: add a Detached row for each
    /// session nothing attaches, and take away rows whose session has gone
    /// or now has a row of its own, unless they are attached here.
    private func reconcileDetached() {
        guard configuration.findsDetachedSessions else { return }
        let rows = lanes.filter { !detachedIDs.contains($0.id) }
        let wanted = DetachedSessions.unclaimed(discovered, lanes: rows, backends: backends, heldSessionIDs: heldSessionIDs)
        let wantedIDs = Set(wanted.map(DetachedSessions.laneID))
        for id in detachedIDs where !wantedIDs.contains(id) && sessions[id]?.isAttached != true {
            removeDetachedRow(id)
        }
        for found in wanted where backends[found.backendID] != nil {
            let lane = DetachedSessions.lane(for: found)
            guard !detachedIDs.contains(lane.id), !lanes.contains(where: { $0.id == lane.id }) else { continue }
            detachedIDs.insert(lane.id)
            lanes.append(lane)
            makeSession(for: lane)
        }
        apply(statusFeed?.records ?? [])
        if let presence = statusFeed?.presence { apply(presence: presence) }
    }

    /// Drop sessions a lane's row attached from the last sweep, once the
    /// lane has stopped them, so they are not listed again before the next.
    private func forgetDiscovered(claimedBy lane: AgentLane, backend: any LaneBackend) {
        discovered.removeAll { $0.backendID == lane.backendID && DetachedSessions.claims(lane, backend: backend, $0.session) }
    }

    private func removeDetachedRow(_ id: AgentLane.ID) {
        guard detachedIDs.remove(id) != nil else { return }
        sessions[id]?.detach()
        sessions.removeValue(forKey: id)
        lanes.removeAll { $0.id == id }
        if splitID == id { splitID = nil }
        if selectedID == id { selectedID = displayOrder.first?.id }
    }

    /// Make a Detached row a lane of the person's own: it moves to `section`
    /// (nil for none), attaches here in the background if it is not already,
    /// and from then on is kept like any lane they opened, so the restore
    /// snapshot and workspaces record it with its session's name.
    public func adopt(_ id: AgentLane.ID, into section: String?) {
        guard detachedIDs.contains(id), let index = lanes.firstIndex(where: { $0.id == id }),
              let session = sessions[id] else { return }
        detachedIDs.remove(id)
        var lane = lanes[index]
        lane.isClosable = true
        lane.section = section
        lanes[index] = lane
        session.update(lane: lane)
        layout.move(id, to: section)
        attachInBackground(id)
        objectWillChange.send()
    }

    // MARK: Dock

    /// Whether the bottom dock (``AgentLaneDock``) is open.
    @Published public private(set) var dockVisible = false
    /// The dock fills the window, the app's content hidden behind it.
    @Published public var dockMaximized = false {
        didSet { defaults.set(dockMaximized, forKey: keys.dockMaximized) }
    }
    private weak var focusBeforeDock: NSResponder?

    /// Open the dock in the mode it was last in, starting a lane if there
    /// is none, and give the selected terminal the keyboard.
    public func showDock(newLaneDirectory: URL? = nil) {
        if !dockVisible {
            focusBeforeDock = NSApp.keyWindow?.firstResponder
            dockMaximized = defaults.bool(forKey: keys.dockMaximized)
        }
        dockVisible = true
        if lanes.isEmpty { openNewLane(in: newLaneDirectory) } else { openSelected(focus: true) }
    }

    /// Close the dock and hand the keyboard back to whatever had it before.
    public func hideDock() {
        guard dockVisible else { return }
        dockVisible = false
        if let focus = focusBeforeDock, let window = NSApp.keyWindow {
            window.makeFirstResponder(focus)
        }
        focusBeforeDock = nil
    }

    public func toggleDock(newLaneDirectory: URL? = nil) {
        if dockVisible { hideDock() } else { showDock(newLaneDirectory: newLaneDirectory) }
    }

    // MARK: Sending text

    /// Type `text` into a lane's agent without switching to it. When no
    /// program there takes a paste, the text goes on the clipboard instead
    /// and the result says so.
    public enum SendResult: Equatable, Sendable { case sent, copied }

    @discardableResult
    public func send(_ text: String, to id: AgentLane.ID? = nil, submit: Bool = false) -> SendResult {
        if let session = (id ?? selectedID).flatMap({ sessions[$0] }), session.send(text, submit: submit) {
            return .sent
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .copied
    }

    // MARK: Naming, duplicating, switching agent

    /// Give a row a name of the person's own; nil returns to the automatic name.
    /// A new name also renames the agent's own session, when its backend has
    /// a ``LaneBackend/renameCommand`` and ``renamesAgentSession`` is on;
    /// see ``renameAgentSession(_:to:)``.
    public func rename(_ id: AgentLane.ID, to name: String?) {
        let before = sessions[id]?.customTitle
        setName(id, to: name)
        if let value = sessions[id]?.customTitle, value != before { renameAgentSession(id, to: value) }
    }

    /// The row's name only, as a restored or duplicated lane takes it.
    func setName(_ id: AgentLane.ID, to name: String?) {
        let name = name?.trimmingCharacters(in: .whitespaces)
        let value = name?.isEmpty == false ? name : nil
        sessions[id]?.customTitle = value
        if let value { layout.names[id] = value } else { layout.names.removeValue(forKey: id) }
    }

    /// Type the backend's rename command into the lane's agent, so its own
    /// session takes the name too. It is typed only when the lane is attached
    /// here, the agent has the terminal, is not running a turn or asking
    /// permission, and its input line reads as empty; otherwise nothing is
    /// typed, and the row says why for a moment when that is worth knowing.
    @discardableResult
    public func renameAgentSession(_ id: AgentLane.ID, to name: String) -> AgentRenameOutcome {
        guard let session = sessions[id] else { return .notAttached }
        let command = session.backend.renameCommand.flatMap { LaneRename.command(format: $0, name: name) }
        let outcome = AgentRenameOutcome.decide(command: command, enabled: renamesAgentSession,
                                                attached: session.isAttached, agentInForeground: session.acceptsText,
                                                state: session.record?.state, input: session.readInputLine)
        if outcome == .sent, let command { session.typeCommand(command) }
        session.showRenameNotice(outcome.notice)
        return outcome
    }

    /// The person's switch for renaming the agent's session with its lane,
    /// saved under ``AgentsModeKeys/renameAgentSession``; on unless they
    /// turn it off.
    public var renamesAgentSession: Bool {
        get { defaults.object(forKey: keys.renameAgentSession) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: keys.renameAgentSession)
            objectWillChange.send()
        }
    }

    /// Whether any registered backend can rename its agent's session, so
    /// Settings shows the switch.
    public var agentRenameAvailable: Bool { backends.values.contains { $0.renameCommand != nil } }

    /// Told when the person picks an icon or colour for a lane, with the new
    /// choice (nil for each means back to the app's own), so an app can keep
    /// it in its own model too.
    public var onIconChange: ((AgentLane, LaneIcon?, String?) -> Void)?

    /// Give a lane an icon and colour of the person's choosing; nil for both
    /// returns it to the app's own. Kept in ``layout``, so it survives
    /// relaunch and an app that syncs its lanes again.
    public func setIcon(_ icon: LaneIcon?, tint: String?, for id: AgentLane.ID) {
        layout.setIcon(icon, tint: tint, for: id)
        if let session = sessions[id] { applyIconOverride(to: session) }
        if let lane = lanes.first(where: { $0.id == id }) { onIconChange?(lane, icon, layout.tints[id]) }
    }

    private func applyIconOverride(to session: AgentLaneSession) {
        session.customIcon = layout.icons[session.id].flatMap(LaneIcon.init)
        session.customTintHex = layout.tints[session.id]
    }

    /// Backends whose command is installed on this Mac (others always count).
    public var installedBackends: [any LaneBackend] {
        availableBackends.filter { $0.id != Self.customBackendID && (($0 as? CommandLaneBackend)?.isInstalled ?? true) }
    }

    /// The id of the backend built from the person's own command in Settings.
    public static let customBackendID = "agentsmate.custom"

    /// What a new lane runs: the person's choice in Settings, else the first
    /// installed backend.
    public var newLaneBackendID: String {
        let saved = defaults.string(forKey: keys.newLaneBackend) ?? ""
        if saved == Self.customBackendID {
            let command = defaults.string(forKey: keys.newLaneCommand)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !command.isEmpty {
                register(CommandLaneBackend(id: Self.customBackendID, displayName: command.split(separator: " ").first.map(String.init) ?? command,
                                            command: command, returnsToShell: true))
                return Self.customBackendID
            }
        }
        if backends[saved] != nil { return saved }
        return installedBackends.first?.id ?? CommandLaneBackend.shell.id
    }

    /// Open a lane the person can close, in `directory`, running what
    /// Settings says a new lane runs.
    @discardableResult
    public func openNewLane(in directory: URL? = nil, backendID: String? = nil, focus: Bool = true,
                            open shouldOpen: Bool = true, section: String? = nil) -> AgentLaneSession? {
        let id = backendID ?? newLaneBackendID
        if backends[id] == nil, id == CommandLaneBackend.shell.id { register(CommandLaneBackend.shell) }
        let name = backends[id]?.displayName ?? "Lane"
        let lane = AgentLane(id: UUID().uuidString, title: directory.map { "\(name) · \($0.lastPathComponent)" } ?? name,
                             directory: directory, backendID: id, isClosable: true, section: section)
        return add(lane, focus: focus, open: shouldOpen)
    }

    /// What happens at launch, as Settings says: reopen the lanes open at
    /// quit (or the launch workspace), else open one new lane in the
    /// background, else nothing.
    public func performLaunchBehavior(newLaneDirectory: URL? = nil) {
        defer { restoreSettled = true }
        let reopen = defaults.object(forKey: keys.reopenLast) as? Bool ?? true
        if reopen, configuration.workspaceFile != nil, restoreAtLaunch() { return }
        if defaults.bool(forKey: keys.openAtLaunch), !lanes.contains(where: \.isClosable) {
            openNewLane(in: newLaneDirectory, focus: false, open: false)
        }
    }

    /// Every backend a lane can run on, by name.
    public var availableBackends: [any LaneBackend] {
        backends.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// A new lane like this one, in the same folder and section, just after
    /// it, named "<name> 2" (or the next free number), running `backendID`
    /// or the same backend.
    @discardableResult
    public func duplicate(_ id: AgentLane.ID, backendID: String? = nil, focus: Bool = true) -> AgentLaneSession? {
        guard let source = lanes.first(where: { $0.id == id }), let session = sessions[id] else { return nil }
        var lane = source
        lane.id = UUID().uuidString
        lane.isClosable = true
        lane.backendID = backendID ?? source.backendID
        lane.section = layout.section(of: source)
        lane.statusMatch = nil
        // The copy is a lane of its own, not another view of the same session.
        lane.sessionName = nil
        if source.directory == nil { lane.directory = URL(fileURLWithPath: session.currentDirectory) }
        // A persistent lane in the same folder would attach the same session,
        // so the copy asks for a lane of its own: the next free number.
        lane.variant = nil
        lane.variant = freeVariant(for: lane)
        let taken = Set(sessions.values.map(\.title))
        let name = session.title.nextCopyName(taken: taken)
        let added = add(lane, focus: focus, after: id)
        setName(lane.id, to: name)
        return added
    }

    /// The variant a new lane needs so it is a session of its own: nil when
    /// its backend's sessions end with their terminal or no lane of that
    /// backend uses its folder, else the next free number from 2.
    func freeVariant(for lane: AgentLane) -> String? {
        guard let backend = backends[lane.backendID], backend.keepsRunningWhenDetached else { return nil }
        let path = LaneStatusMatch.normalizedPath(lane.path)
        let sharing = lanes.filter { $0.backendID == lane.backendID && LaneStatusMatch.normalizedPath($0.path) == path }
        guard !sharing.isEmpty else { return nil }
        let used = Set(sharing.map { $0.variant ?? "1" })
        var n = 2
        while used.contains(String(n)) { n += 1 }
        return String(n)
    }

    // MARK: New lane in a section

    /// An `NSOpenPanel` for one folder, as a sheet on the key window when
    /// there is one. The default ``Configuration/chooseFolder``.
    public static func chooseFolderWithOpenPanel(startingAt folder: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose the folder the new lane works in."
        panel.directoryURL = folder
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    /// The group a lane is shown in.
    public func group(containing id: AgentLane.ID) -> LaneGroup? {
        groups.first { $0.lanes.contains { $0.id == id } }
    }

    /// Whether a group's + can start a lane in it: every group but Detached.
    public func canAddLane(to group: LaneGroup) -> Bool { !group.isDetached }

    /// Where the folder chooser opens for a new lane in `group`: the
    /// selected lane's folder when it is in the group, else the first
    /// lane's, else nil.
    public func startingFolder(for group: LaneGroup) -> URL? {
        let member = group.lanes.first { $0.id == selectedID } ?? group.lanes.first
        guard let member else { return nil }
        if let directory = member.directory { return directory }
        return sessions[member.id].map { URL(fileURLWithPath: $0.currentDirectory, isDirectory: true) }
    }

    /// Ask for a folder with ``Configuration/chooseFolder``, then open a
    /// lane running `backendID` there, in `group`'s section (pinned when
    /// `group` is Pinned), and select it. Cancelling changes nothing. A
    /// folder another lane of that backend already uses gets a session of
    /// its own (``AgentLane/variant``).
    @discardableResult
    public func newLane(in group: LaneGroup, backendID: String, focus: Bool = true) async -> AgentLaneSession? {
        guard canAddLane(to: group), backends[backendID] != nil else { return nil }
        guard let folder = await configuration.chooseFolder(startingFolder(for: group)) else { return nil }
        let section = group.isPinned ? nil : group.section
        let name = backends[backendID]?.displayName ?? "Lane"
        var lane = AgentLane(id: UUID().uuidString, title: "\(name) · \(folder.lastPathComponent)",
                             directory: folder, backendID: backendID, isClosable: true, section: section)
        lane.variant = freeVariant(for: lane)
        if let variant = lane.variant { lane.title += " \(variant)" }
        // A person's move wins over a lane's own section, so record this
        // one as theirs: the lane stays where its + was pressed.
        layout.move(lane.id, to: section)
        if group.isPinned { layout.setPinned(lane.id, true) }
        return add(lane, focus: focus)
    }

    /// Run a lane the person opened on another backend, keeping its name,
    /// section and place. Its terminal restarts.
    /// Fixed lanes the person reopened as another agent, by lane id.
    private var backendOverrides: [AgentLane.ID: String] {
        get { (defaults.dictionary(forKey: keys.backendOverrides) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: keys.backendOverrides) }
    }

    /// Reopen a lane running another agent: the row keeps its place, name and
    /// folder, and attaches with `backendID` from now on. The session it was
    /// attached to keeps running, so its conversation can be reopened later.
    public func reopen(_ id: AgentLane.ID, as backendID: String) {
        guard let index = lanes.firstIndex(where: { $0.id == id }), let backend = backends[backendID],
              let session = sessions[id] else { return }
        if lanes[index].backendID != backendID {
            if !lanes[index].isClosable { backendOverrides[id] = backendID }
            session.detach()
            lanes[index].backendID = backendID
            session.update(lane: lanes[index])
            session.update(backend: backend)
            apply(statusFeed?.records ?? [])
        }
        open(id)
    }

    /// Reopen the selected lane as the `index`th choice (zero-based).
    public func reopenSelected(choice index: Int) {
        guard let id = selectedID, configuration.reopenChoices.indices.contains(index) else { return }
        reopen(id, choice: configuration.reopenChoices[index])
    }

    /// Reopen a lane as `choice`: on its backend, or for
    /// ``LaneReopenChoice/Kind/sameAgent`` on the backend it has now, in a
    /// fresh terminal.
    public func reopen(_ id: AgentLane.ID, choice: LaneReopenChoice) {
        if choice.kind == .sameAgent { reattach(id) } else { reopen(id, as: choice.backendID) }
    }

    /// The first Reopen As choice of `kind`, if the app offers one.
    public func reopenChoice(_ kind: LaneReopenChoice.Kind) -> LaneReopenChoice? {
        configuration.reopenChoices.first { $0.kind == kind }
    }

    /// Reopen a lane as the app's choice of `kind`. False when the app
    /// offers none, or there is no such lane.
    @discardableResult
    public func reopen(_ id: AgentLane.ID, kind: LaneReopenChoice.Kind) -> Bool {
        guard sessions[id] != nil, let choice = reopenChoice(kind) else { return false }
        reopen(id, choice: choice)
        return true
    }

    /// Reopen the selected lane as the app's choice of `kind`.
    @discardableResult
    public func reopenSelected(kind: LaneReopenChoice.Kind) -> Bool {
        guard let id = selectedID else { return false }
        return reopen(id, kind: kind)
    }

    public func switchBackend(_ id: AgentLane.ID, to backendID: String) {
        guard let index = lanes.firstIndex(where: { $0.id == id }), lanes[index].isClosable,
              lanes[index].backendID != backendID, let backend = backends[backendID],
              let session = sessions[id] else { return }
        let wasAttached = session.isAttached
        lanes[index].backendID = backendID
        session.update(lane: lanes[index])
        session.update(backend: backend)
        if wasAttached { reattach(id) }
        apply(statusFeed?.records ?? [])
    }

    private func makeSession(for lane: AgentLane) {
        if let existing = sessions[lane.id] {
            existing.update(lane: lane)
            applyIconOverride(to: existing)
            return
        }
        guard let backend = backends[lane.backendID] ?? backends["shell"] ?? Optional(CommandLaneBackend.shell) else { return }
        let session = AgentLaneSession(lane: lane, backend: backend)
        let id = lane.id
        session.onWantsAttention = { [weak self] session in self?.laneWantsAttention(session) }
        session.customTitle = layout.names[id]
        session.onShortcut = { [weak self] shortcut in self?.handle(shortcut, from: id) ?? false }
        session.shortcutResolver = { [weak self] event in self?.shortcuts.terminalShortcut(for: event) }
        session.onOpenLink = { [weak self] url in self?.onOpenLink?(url, id) ?? false }
        session.onSectionFromAgent = { [weak self] section in
            guard let self, self.layout.assignments[id] == nil, self.layout.section(of: lane) != section else { return }
            self.layout.move(id, to: section)
        }
        session.onDirectoryChange = { [weak self] session in self?.laneDirectoryChanged(session) }
        session.onAttachmentChange = { [weak self] session in
            guard let self else { return }
            if session.isStarted { self.restoredPending.remove(session.id) }
            self.scheduleRestoreWrite()
        }
        applyIconOverride(to: session)
        if summariesEnabled { session.summary = summaries?.summary(for: id) }
        session.pullRequests = pullRequestLedger?.pullRequests(for: id) ?? []
        sessions[lane.id] = session
        session.isSelected = id == selectedID || id == splitID
        session.isShown = isShowing && session.isSelected
    }

    /// Show a lane, attaching it the first time or after it ended. Opening a
    /// lane that is already attached only shows it.
    public func open(_ id: AgentLane.ID, focus: Bool = true) {
        guard let session = sessions[id] else { return }
        recordVisit(id)
        if id == splitID { splitID = selectedID == id ? nil : selectedID }
        selectedID = id
        let starting = !session.isAttached
        start(session)
        if focus { session.wantsFocus = true }
        updateShown()
        if starting, !detachedIDs.contains(id) { claimAfterAttach() }
    }

    /// How long after a row attaches its wrapper is given to record the
    /// session it picked up, before the row is matched against Detached again.
    static let claimDelay: TimeInterval = 3
    private var claimTask: Task<Void, Never>?

    /// A row just attached: match its session against Detached once now and
    /// once its wrapper has had time to record the session id, so a
    /// Detached row for the same session goes at once rather than at the
    /// next sweep. Reads no more than the status match already does.
    private func claimAfterAttach() {
        guard configuration.findsDetachedSessions, !discovered.isEmpty else { return }
        apply(statusFeed?.records ?? [])
        claimTask?.cancel()
        claimTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.claimDelay))
            guard !Task.isCancelled, let self else { return }
            self.claimTask = nil
            self.apply(self.statusFeed?.records ?? [])
        }
    }

    public func openSelected(focus: Bool = true) {
        guard let id = selectedID ?? lanes.first?.id else { return }
        open(id, focus: focus)
    }

    /// The lanes as the list shows them, grouped.
    public var groups: [LaneGroup] {
        let detached = detachedIDs
        var groups = layout.groups(for: detached.isEmpty ? lanes : lanes.filter { !detached.contains($0.id) }) { [sessions] lane in
            sessions[lane.id]?.lastActivity
        }
        let found = lanes.filter { detached.contains($0.id) }
        if !found.isEmpty {
            groups.append(LaneGroup(section: LaneLayout.detachedSection, lanes: found, isDetached: true))
        }
        return groups
    }

    /// The lanes in the order the list shows them; ⌘1–⌘9 and cycling follow it.
    public var displayOrder: [AgentLane] {
        groups.flatMap(\.lanes)
    }

    public func open(index: Int) {
        let ordered = displayOrder
        guard ordered.indices.contains(index) else { return }
        open(ordered[index].id)
    }

    // MARK: Layout

    public func addSection(_ name: String) { layout.addSection(name) }
    public func renameSection(_ old: String, to new: String) { layout.renameSection(old, to: new, lanes: lanes) }
    public func removeSection(_ name: String) { layout.removeSection(name, lanes: lanes) }
    public func moveSection(_ name: String, by offset: Int) { layout.moveSection(name, by: offset, lanes: lanes) }
    /// Put a section before another, or last when `target` is nil.
    public func moveSection(_ name: String, before target: String?) {
        layout.moveSection(name, before: target, lanes: lanes)
    }
    public func move(_ id: AgentLane.ID, to section: String?) { layout.move(id, to: section) }
    public func setPinned(_ id: AgentLane.ID, _ pinned: Bool) { layout.setPinned(id, pinned) }
    public func moveLane(_ id: AgentLane.ID, before target: AgentLane.ID?) {
        layout.moveLane(id, before: target, lanes: lanes)
    }
    public func setSort(_ sort: LaneLayout.Sort) { layout.sort = sort }

    public func toggleCollapsed(_ section: String) {
        if layout.collapsed.contains(section) { layout.collapsed.remove(section) } else { layout.collapsed.insert(section) }
    }

    public func setAllCollapsed(_ collapsed: Bool) {
        layout.collapsed = collapsed
            ? Set(layout.orderedSections(for: lanes) + [LaneLayout.pinnedSection, LaneLayout.detachedSection,
                                                        LaneLayout.unsectionedKey]) : []
    }

    /// Fold every group but `group`, and open it.
    public func collapseOtherSections(than group: LaneGroup) {
        layout.collapseOthers(than: group.collapseKey, groups: groups)
    }

    /// Fold every group but the one the selected lane is in.
    public func collapseOtherSectionsThanSelected() {
        guard let id = selectedID, let group = group(containing: id) else { return }
        collapseOtherSections(than: group)
    }

    /// Whether folding the others would change anything.
    public func canCollapseOtherSections(than group: LaneGroup) -> Bool {
        groups.count > 1 && Set(groups.map(\.collapseKey)).subtracting([group.collapseKey]) != layout.collapsed
    }

    /// Every section a lane can be moved to.
    public var sectionNames: [String] { layout.orderedSections(for: lanes) }

    public func detach(_ id: AgentLane.ID) { sessions[id]?.detach() }

    public func reattach(_ id: AgentLane.ID) {
        guard let session = sessions[id] else { return }
        session.detach()
        open(id)
    }

    /// End the lane's session, not just the terminal here. Its conversation
    /// is kept, so opening the lane again resumes it.
    /// A Detached row goes with its session.
    public func stop(_ id: AgentLane.ID) {
        guard let session = sessions[id], session.backend.canStop(session.lane) else { return }
        session.detach()
        session.backend.stop(session.lane)
        if detachedIDs.contains(id) {
            discovered.removeAll { DetachedSessions.laneID($0) == id }
            removeDetachedRow(id)
        } else {
            forgetDiscovered(claimedBy: session.lane, backend: session.backend)
        }
        statusFeed?.reload()
    }

    /// Whether the lane's session can be stopped from here.
    public func canStop(_ id: AgentLane.ID) -> Bool {
        guard let session = sessions[id] else { return false }
        return session.backend.canStop(session.lane)
    }

    /// End and remove a lane the person opened. Its session keeps running
    /// unless ``Configuration/closeStopsLane`` is on.
    public func close(_ id: AgentLane.ID) {
        guard let index = lanes.firstIndex(where: { $0.id == id }), lanes[index].isClosable else { return }
        if configuration.closeStopsLane, let session = sessions[id], session.backend.canStop(session.lane) {
            session.backend.stop(session.lane)
            forgetDiscovered(claimedBy: session.lane, backend: session.backend)
        }
        let decision = willCloseLane?(lanes[index], sessions[id]?.isAttached == true) ?? .remove
        if decision == .keepRow {
            // The row stays, its terminal ended, ready to start again.
            sessions[id]?.detach()
            sessions.removeValue(forKey: id)
            makeSession(for: lanes[index])
            apply(statusFeed?.records ?? [])
            didCloseLane?(lanes[index], .keepRow)
            return
        }
        let closed = lanes[index]
        restoredPending.remove(id)
        defer {
            // A session left running shows in Detached again.
            reconcileDetached()
            didCloseLane?(closed, .remove)
        }
        sessions[id]?.detach()
        sessions.removeValue(forKey: id)
        lanes.remove(at: index)
        if splitID == id { splitID = nil }
        if selectedID == id {
            let neighbour = lanes.indices.contains(index) ? lanes[index] : lanes.last
            selectedID = neighbour?.id == splitID ? lanes.first { $0.id != splitID }?.id : neighbour?.id
            selected?.wantsFocus = true
        }
    }

    public func cycle(by offset: Int) {
        var ordered = displayOrder
        if configuration.cycleSkipsUnstarted {
            let started = ordered.filter { sessions[$0.id]?.isStarted == true || $0.id == selectedID }
            if !started.isEmpty { ordered = started }
        }
        guard !ordered.isEmpty else { return }
        let index = ordered.firstIndex { $0.id == selectedID } ?? 0
        open(ordered[(index + offset + ordered.count) % ordered.count].id)
    }

    /// Show a second lane beside the selected one, or stop showing it. The
    /// app chooses what a new split runs through `onNewLane`; with no
    /// handler the next lane in the list is used.
    public func toggleSplit() {
        if splitID != nil {
            splitID = nil
            return
        }
        let current = selectedID
        if let onNewLane {
            onNewLane()
            let added = selectedID
            selectedID = current
            splitID = added == current ? nil : added
        } else if let current, let index = lanes.firstIndex(where: { $0.id == current }), lanes.count > 1 {
            let other = lanes[(index + 1) % lanes.count].id
            if let other = sessions[other] { start(other) }
            splitID = other
        }
        updateShown()
    }

    public func clearSelected() { selected?.view.clearScreen() }

    // MARK: Text size

    public var fontSize: CGFloat {
        min(max(configuration.baseFontSize + fontOffset, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    public var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    public func adjustFont(by points: CGFloat) {
        let target = min(max(fontSize + points, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        setFontOffset(target - configuration.baseFontSize)
    }

    /// Back to the app's or the system's size.
    public func resetFont() { setFontOffset(0) }

    private func setFontOffset(_ offset: CGFloat) {
        guard offset != fontOffset else { return }
        fontOffset = offset
        defaults.set(Double(offset), forKey: keys.fontOffset)
        applyFont()
    }

    private func applyFont() {
        let font = self.font
        for session in sessions.values where session.isStarted { session.view.font = font }
    }

    public func detachAll() { sessions.values.forEach { $0.detach() } }

    /// Whether the selected lane has a terminal running here.
    public var selectedIsAttached: Bool { selected?.isAttached == true }

    @discardableResult
    func handle(_ shortcut: TerminalShortcut, from id: AgentLane.ID) -> Bool {
        guard configuration.shortcuts.contains(shortcut.member) else { return false }
        switch shortcut {
        case .newLane:
            guard let onNewLane else { return false }
            onNewLane()
        case .closeLane:
            guard lanes.first(where: { $0.id == id })?.isClosable == true else { return false }
            close(id)
        case .split: toggleSplit()
        case .clear: sessions[id]?.view.clearScreen()
        case .next: cycle(by: 1)
        case .previous: cycle(by: -1)
        case .select(let n): open(index: n)
        case .maximize:
            guard dockVisible else { return false }
            dockMaximized.toggle()
        case .togglePanel:
            guard dockVisible else { return false }
            hideDock()
        case .biggerFont: adjustFont(by: 1)
        case .smallerFont: adjustFont(by: -1)
        case .resetFont: resetFont()
        case .reopen(let kind): return reopen(id, kind: kind)
        }
        return true
    }

    private func apply(_ records: [LaneStatus]) {
        var held: [AgentLane.ID: [String]] = [:]
        for session in sessions.values {
            let match = session.lane.statusMatch ?? session.backend.statusMatch(for: session.lane)
            let record = match.find(in: records)
            session.update(record: record)
            if !detachedIDs.contains(session.id) {
                let ids = DetachedSessions.heldSessionIDs(match: match, record: record)
                if !ids.isEmpty { held[session.id] = ids }
            }
        }
        objectWillChange.send()
        // A row that has just picked up a session (its wrapper wrote the id,
        // or a hook reported it) takes it out of Detached now, not at the
        // next sweep. Nothing runs here: the last sweep is matched again.
        if held != heldSessionIDs {
            heldSessionIDs = held
            if !discovered.isEmpty { reconcileDetached() }
        }
    }

    /// A note is found by the lane's id, or by the tmux session its status
    /// matches by name.
    private func apply(notes: [String: LaneNote]) {
        for session in sessions.values {
            var note = notes[session.id]
            if note == nil, case .lane(let name)? = session.lane.statusMatch ?? Optional(session.backend.statusMatch(for: session.lane)) {
                note = notes[name]
            }
            if note == nil, let lane = session.record?.lane { note = notes[lane] }
            if session.note != note { session.note = note }
        }
    }

    private func apply(presence: [LanePresence]) {
        for session in sessions.values {
            let match = session.lane.statusMatch ?? session.backend.statusMatch(for: session.lane)
            let found = presence.find(for: session.lane, match: match)
            session.update(orphan: configuration.highlightsOrphans && found?.attachedClients == 0 && !session.isAttached)
            session.update(present: found != nil)
        }
        objectWillChange.send()
    }

    // MARK: Transcripts

    private var transcriptTimer: CadenceTimer?
    private var transcripts = LaneTranscriptCache()
    private var readingTranscripts = false

    private func startTranscripts() {
        transcriptTimer = CadenceTimer(interval: TranscriptSchedule.interval(showing: isShowing)) { [weak self] in
            self?.refreshTranscripts()
        }
    }

    /// Read what each lane's conversation file gained, off the main actor,
    /// for files whose size or modification time changed. Skipped while the
    /// last read is still going.
    func refreshTranscripts() {
        guard !readingTranscripts else { return }
        var wanted: [AgentLane.ID: LaneTranscriptCache.Source] = [:]
        for (id, session) in sessions {
            if let source = LaneTranscriptCache.Source(session.record) { wanted[id] = source }
        }
        guard !wanted.isEmpty else { return }
        readingTranscripts = true
        let cache = transcripts
        Task.detached(priority: .background) {
            var cache = cache
            let changed = cache.read(Set(wanted.values))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.readingTranscripts = false
                self.transcripts = cache
                var selectedChanged = false
                for (id, source) in wanted {
                    guard let path = cache.path(for: source), let transcript = changed[path] else { continue }
                    self.sessions[id]?.update(transcript: transcript)
                    self.pullRequestLedger?.record(transcript.pullRequestLinks, lane: id)
                    self.summarize(id, transcript: transcript, path: path)
                    if id == self.selectedID { selectedChanged = true }
                }
                // The menu bar's Copy Last Prompt follows the selected lane.
                if selectedChanged { self.objectWillChange.send() }
                self.summaries?.tick()
            }
        }
    }

    // MARK: Summaries

    private var summaries: LaneSummaries?

    /// Whether the app turned summaries on (``Configuration/summaryModel``).
    public var summariesAvailable: Bool { configuration.summaryModel != nil }

    /// The person's switch for summaries, saved under
    /// ``AgentsModeKeys/summarizeSessions``; on unless they turn it off.
    /// Off stops new summaries and hides the ones already written.
    public var summariesEnabled: Bool {
        get { summariesAvailable && (defaults.object(forKey: keys.summarizeSessions) as? Bool ?? true) }
        set {
            defaults.set(newValue, forKey: keys.summarizeSessions)
            objectWillChange.send()
            for (id, session) in sessions {
                let summary = newValue ? summaries?.summary(for: id) : nil
                if session.summary != summary { session.summary = summary }
            }
            if newValue { refreshTranscripts() }
        }
    }

    private func startSummaries() {
        guard let model = configuration.summaryModel else { return }
        var all: [any LaneSummarizing] = [ClaudeLaneSummarizer(model: model),
                                          CodexLaneSummarizer(model: configuration.codexSummaryModel)]
        all += configuration.summarizers
        let summaries = LaneSummaries(summarizers: all, cache: configuration.summaryCacheFile.map(LaneSummaryCache.init(url:)))
        summaries.onSummary = { [weak self] id, summary in
            guard let self, self.summariesEnabled, let session = self.sessions[id], session.summary != summary else { return }
            session.summary = summary
            self.objectWillChange.send()
        }
        self.summaries = summaries
    }

    private func summarize(_ id: AgentLane.ID, transcript: LaneTranscript, path: String) {
        guard let summaries, summariesEnabled, let agent = sessions[id]?.record?.agent,
              let digest = TranscriptDigest(transcript) else { return }
        summaries.retain(Set(sessions.keys))
        summaries.consider(id, agent: agent, source: path, digest: digest)
    }

    // MARK: Pull requests

    private var pullRequestLedger: PullRequestLedger?

    private func startPullRequestLedger() {
        let resolvers = configuration.pullRequestResolvers + [GitHubPullRequestResolver()]
        let ledger = PullRequestLedger(resolvers: resolvers,
                                       cache: configuration.pullRequestLedgerFile.map(PullRequestLedgerCache.init(url:)),
                                       seedFile: configuration.pullRequestSeedFile)
        ledger.onChange = { [weak self] ids in
            guard let self else { return }
            for id in ids {
                guard let session = self.sessions[id] else { continue }
                let found = ledger.pullRequests(for: id)
                if session.pullRequests != found { session.pullRequests = found }
            }
        }
        pullRequestLedger = ledger
        ledger.tick()
    }

    /// Add pull request links to a lane's ledger as if its agent had posted
    /// them, for an app that learns of them another way. Untrusted links
    /// are dropped.
    public func recordPullRequests(_ urls: [URL], for id: AgentLane.ID) {
        pullRequestLedger?.record(urls, lane: id)
    }

    /// Open one of a lane's pull requests. The agent's links go through
    /// ``openPullRequest(_:)``; the branch's, which `gh` reported, open in
    /// the browser when they are not on a trusted host.
    @discardableResult
    public func open(_ pullRequest: LanePullRequest) -> Bool {
        if openPullRequest(pullRequest.url) { return true }
        guard pullRequest.source == .branch, pullRequest.url.scheme == "https" else { return false }
        NSWorkspace.shared.open(pullRequest.url)
        return true
    }

    /// Put the lane's summary on the pasteboard. False when it has none.
    @discardableResult
    public func copySummary(of id: AgentLane.ID) -> Bool {
        guard let summary = sessions[id]?.summary, !summary.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        return true
    }

    /// Put the person's last prompt in the lane on the pasteboard. False
    /// when its conversation has none yet.
    @discardableResult
    public func copyLastPrompt(of id: AgentLane.ID) -> Bool {
        guard let prompt = sessions[id]?.recentPrompts.last, !prompt.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        return true
    }

    private func updateShown() {
        for (id, session) in sessions {
            session.isSelected = id == selectedID || id == splitID
            session.isShown = isShowing && session.isSelected
            if session.isShown { notifier?.clear(id) }
        }
    }
}

/// The UserDefaults keys Agents mode saves its state under.
public struct AgentsModeKeys: Sendable {
    public let prefix: String
    public init(prefix: String) { self.prefix = prefix }
    public var selectedLane: String { prefix + "selectedLane" }
    public var filterOpen: String { prefix + "filterOpen" }
    public var filterRunning: String { prefix + "filterRunning" }
    public var filterWaiting: String { prefix + "filterWaiting" }
    public var filterIdle: String { prefix + "filterIdle" }
    public var fontOffset: String { prefix + "fontOffset" }
    public var layout: String { prefix + "layout" }
    public var shortcuts: String { prefix + "shortcuts" }
    public var newLaneBackend: String { prefix + "newLaneBackend" }
    public var newLaneCommand: String { prefix + "newLaneCommand" }
    public var openAtLaunch: String { prefix + "openAtLaunch" }
    public var reopenLast: String { prefix + "reopenLast" }
    public var dockHeight: String { prefix + "dockHeight" }
    public var dockMaximized: String { prefix + "dockMaximized" }
    public var dockListWidth: String { prefix + "dockListWidth" }
    public var backendOverrides: String { prefix + "backendOverrides" }
    /// The person's switch for one-line lane summaries.
    public var summarizeSessions: String { prefix + "summarizeSessions" }
    /// The person's switch for renaming the agent's session with its lane.
    public var renameAgentSession: String { prefix + "renameAgentSession" }
}
