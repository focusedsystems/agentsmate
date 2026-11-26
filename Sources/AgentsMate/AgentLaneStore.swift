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
        /// How far a lane's terminal scrolls for a given trackpad travel or
        /// wheel turn. 1 moves a line per row height of trackpad travel and
        /// a step per wheel notch; above 1 is faster, below slower.
        public var scrollSensitivity: CGFloat
        /// The shortcuts a focused terminal answers itself.
        public var shortcuts: TerminalShortcut.Set
        /// Prefix for the saved filters, selection and text size.
        public var defaultsPrefix: String
        /// Mark lanes whose session runs with no terminal attached anywhere.
        /// Off for an app whose lanes are kept running on purpose.
        public var highlightsOrphans: Bool
        /// No longer used. Closing a lane never stops its session: a lane
        /// attaches a session that outlives the app, so closing its row only
        /// ends the terminal here, the session is listed as a found session
        /// (``findsDetachedSessions``), and Stop Agent is what ends it.
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
        /// Where to read the agents' usage limits; the lane sidebar always
        /// shows the meters at its foot. The default is Claude's status-line
        /// cache and Codex's session files on this Mac
        /// (``AgentUsageSources/standard(claudeHost:)``).
        public var usageSources: [any AgentUsageSource]
        /// What Reopen As offers, in order. Each names a registered backend;
        /// a choice's ``LaneReopenChoice/kind`` gives it that kind's shortcut.
        public var reopenChoices: [LaneReopenChoice]
        /// The agents a new session may start on when the person or the
        /// usage switch picks one. Nil until the app says: then only the
        /// agent of the app's own default is picked. The near-limit switch
        /// works only when the app sets both agents here and
        /// ``agentAllowedForFolder``. The app's default backend is not
        /// checked against it.
        public var allowedAgents: Set<LaneAgentKind>? = nil
        /// Whether an agent may work in a folder, for an app whose agents
        /// are each signed in to an account that may only see some folders.
        /// Without it nothing moves a new session to an agent other than the
        /// app's default: neither the New Sessions choice nor the usage
        /// switch. With it, they apply only to a session whose folder is
        /// known and allowed for the agent picked. It is handed the folder
        /// with symlinks, `~` and `..` resolved, as an absolute path; compare
        /// whole path components (``laneFolder(_:isInside:)``), never a raw
        /// string prefix.
        public var agentAllowedForFolder: (@Sendable (LaneAgentKind, URL) -> Bool)? = nil
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
        /// At launch, about every ten minutes, and soon after the status feed
        /// shows a session start or end, ask each backend for its lane
        /// sessions (``LaneBackend/discoverSessions()``) and list the ones no
        /// row attaches. Each is listed beside the row whose folder holds it
        /// (``placesDetachedSessions``), else in a Detached group.
        public var findsDetachedSessions: Bool
        /// List a session no row attaches just under the row whose folder
        /// holds it, in that row's section, so the list shows every agent
        /// where it works. Off, every such session is in the Detached group.
        public var placesDetachedSessions: Bool
        /// The lane list shared by every Mac through the hub, when the hosts
        /// registry (``AgentHosts``) is there. On by default for an app
        /// bundle; without the registry lanes stay per-Mac. Nil turns it off.
        public var sharedLanes: SharedLaneSettings?
        /// Asks the person for a folder when a section header's + starts a
        /// lane, opening at the folder given (nil for the system's choice),
        /// and returns nil when they cancel. The default is an `NSOpenPanel`
        /// (``AgentLaneStore/chooseFolderWithOpenPanel(startingAt:)``); an
        /// app can offer its own recent folders or repositories instead.
        public var chooseFolder: @MainActor (_ startingAt: URL?) async -> URL?
        /// Read what every lane host has running at launch, so launch can
        /// reattach a lane whose session runs on another Mac
        /// (``HostSessionsConfiguration``). Nil, the default, reads nothing.
        public var hostSessions: HostSessionsConfiguration?
        /// Head the list with its sections (the default; the person can
        /// change it in ``AgentSidebarSettingsSection``). Off, the lanes are one list
        /// with no section headings, for an app with few lanes; the Pinned
        /// and Detached groups keep theirs. With only one section the
        /// heading is left out either way.
        public var showsSectionHeadings: Bool
        /// Draw each row's icon. Off, a row shows its status dot alone.
        public var showsLaneIcons: Bool
        /// Draw pull request pills on rows and All Agents cards. Off by
        /// default; the person can turn them on in ``AgentSidebarSettingsSection``.
        /// Pull requests stay in a row's menu and hover either way.
        public var showsPullRequestPills: Bool
        /// Where a session found for a lane (a parallel session) goes:
        /// a top-level row like its lane's, or indented under it.
        public var parallelSessions: ParallelSessionPlacement
        /// The app's order for its lanes, as folder paths, such as the
        /// order of its repository list: sections come in the order their
        /// first lane does, and lanes within a section in this order. It
        /// applies until the person moves a section or a lane; their order
        /// always wins. Folders not in it follow, in the lanes' order.
        public var defaultRepositoryOrder: [String]
        /// Show All Agents (``AgentHomeView``, first called Home): a board
        /// of every active session, reached from the top of the sidebar and
        /// View ▸ All Agents. Off, the detail area only ever shows terminals.
        public var showsHome: Bool
        /// What the detail area shows the first time Agents mode comes on
        /// screen after launch: Home, attaching nothing until the person
        /// picks a row, or the selected lane, reattached when its session
        /// already runs.
        public var launchShows: AgentsLaunchDestination
        /// Whether a session in a folder, on a host (nil for this Mac), is this
        /// app's to list. Nil lists everything its backends find. Applied to
        /// found sessions and to saved or shared lanes before they get a row,
        /// so a list written by an older version cannot bring one back.
        public var sessionScope: (@Sendable (_ directory: String?, _ host: String?) -> Bool)?
        /// A file an outside watcher keeps of every host's live sessions
        /// (``LiveSessionSnapshot``), read once at launch so the lanes'
        /// states, and the found sessions in ``sessionScope``, show before
        /// any host is asked. What the hosts then say replaces it. Nil reads
        /// nothing. The default is ``LiveSessionSnapshot/standardURL``.
        public var liveSnapshotFile: URL?
        /// Open All Agents with only the active sessions showing: the Active
        /// filter is turned on at each launch. One click on it shows every lane.
        public var opensActiveOnly: Bool
        /// Where the running app writes what its sidebar and All Agents
        /// board show (``DisplayedExport``), so other tools can check them
        /// without a screenshot. Nil turns it off. The default is
        /// ``defaultDisplayedExportFile``: nothing outside an app bundle.
        public var displayedExportFile: URL?
        /// The AgentsMate commit the app was built from, for that file; when
        /// nil, the `AgentsMateCommit` key of the app's Info.plist.
        public var agentsMateCommit: String?
        /// Where apps record which of them the person last worked in for each
        /// session (``SessionOwners``), so that only that app notifies and
        /// badges the Dock for it. Nil turns the gate off: every app notifies.
        /// The default is ``defaultSessionOwnerFile``: nothing outside an app bundle.
        public var sessionOwnerFile: URL?
        /// The bundle id this app records itself under in ``sessionOwnerFile``;
        /// nil is the running bundle's.
        public var ownerAppID: String?
        /// Whether a lane's repository is shared with another app. A lane it
        /// says is not shared is always this app's to notify about; nil
        /// treats every lane that way, so an app that cannot tell notifies as
        /// it always did.
        public var isLaneShared: (@Sendable (_ lane: AgentLane) -> Bool)?

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
                    usageSources: [any AgentUsageSource] = AgentUsageSources.standard(), reopenChoices: [LaneReopenChoice] = [],
                    codexSummaryModel: String? = nil, summarizers: [any LaneSummarizing] = [],
                    summaryCacheFile: URL? = Configuration.defaultSummaryCacheFile, rowStyle: LaneRowStyle = .standard,
                    inboxWindowID: String? = nil, messageWindowID: String? = nil,
                    pullRequestResolvers: [any PullRequestResolver] = [],
                    pullRequestLedgerFile: URL? = Configuration.defaultPullRequestLedgerFile,
                    pullRequestSeedFile: URL? = Configuration.defaultPullRequestSeedFile,
                    findsDetachedSessions: Bool = true,
                    sharedLanes: SharedLaneSettings? = SharedLaneSettings.automatic(),
                    chooseFolder: @escaping @MainActor (_ startingAt: URL?) async -> URL? = AgentLaneStore.chooseFolderWithOpenPanel,
                    scrollSensitivity: CGFloat = 1, placesDetachedSessions: Bool = true,
                    hostSessions: HostSessionsConfiguration? = nil, showsSectionHeadings: Bool = true,
                    defaultRepositoryOrder: [String] = [], showsHome: Bool = true,
                    launchShows: AgentsLaunchDestination = .home, showsLaneIcons: Bool = true,
                    showsPullRequestPills: Bool = false,
                    parallelSessions: ParallelSessionPlacement = .topLevel,
                    liveSnapshotFile: URL? = LiveSessionSnapshot.standardURL, opensActiveOnly: Bool = true,
                    displayedExportFile: URL? = Configuration.defaultDisplayedExportFile,
                    agentsMateCommit: String? = nil,
                    sessionOwnerFile: URL? = Configuration.defaultSessionOwnerFile,
                    ownerAppID: String? = nil,
                    isLaneShared: (@Sendable (_ lane: AgentLane) -> Bool)? = nil) {
            self.sessionOwnerFile = sessionOwnerFile
            self.ownerAppID = ownerAppID
            self.isLaneShared = isLaneShared
            self.displayedExportFile = displayedExportFile
            self.agentsMateCommit = agentsMateCommit
            self.liveSnapshotFile = liveSnapshotFile
            self.opensActiveOnly = opensActiveOnly
            self.showsLaneIcons = showsLaneIcons
            self.showsPullRequestPills = showsPullRequestPills
            self.parallelSessions = parallelSessions
            self.showsHome = showsHome
            self.launchShows = launchShows
            self.hostSessions = hostSessions
            self.showsSectionHeadings = showsSectionHeadings
            self.defaultRepositoryOrder = defaultRepositoryOrder
            self.placesDetachedSessions = placesDetachedSessions
            self.scrollSensitivity = scrollSensitivity
            self.findsDetachedSessions = findsDetachedSessions
            self.sharedLanes = sharedLanes
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
        didSet {
            if lanes != oldValue {
                scheduleRestoreWrite()
                sharedLanes?.localChanged()
                placeDetached()
                updateBadge()
            }
        }
    }
    @Published public private(set) var sessions: [AgentLane.ID: AgentLaneSession] = [:] {
        didSet { if sessions.count != oldValue.count { updateBadge() } }
    }
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
    /// Home is showing in place of the selected lane's terminal. The
    /// selection is kept, so leaving Home goes back to it. Saved.
    @Published public internal(set) var showingHome = false {
        didSet {
            guard showingHome != oldValue else { return }
            defaults.set(showingHome, forKey: keys.showingHome)
            updateShown()
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
        if !session.isAttached, session.attachOnlyLaunch == nil, let launch = boundSessionLaunch(for: session) {
            session.attachOnlyLaunch = launch
        }
        session.start(configuration: configuration, font: font)
    }

    /// The launch for a row whose bindings own a live Claude background
    /// session: `claude attach` of exactly that id, so the pane is the
    /// session the row's summary and status come from, whatever backend the
    /// row defaults to. Nil when no session is bound or the bound one is not
    /// live; then the backend's own launch runs, which never replaces a live
    /// session.
    func boundSessionLaunch(for session: AgentLaneSession) -> TerminalLaunch? {
        guard let config = configuration.hostSessions, let owned = ownedSession(for: session.lane),
              isLive(owned) else { return nil }
        return HostSessions.launch(.claude(id: owned.agentID, host: owned.host), lane: session.lane,
                                   shell: AgentLaneSession.loginShell, config: config)
    }

    /// Whether the Claude background session a row owns is running now, by
    /// its exact short id on its host.
    private func isLive(_ owned: DetachedSessions.OwnedSession) -> Bool {
        let live = { (records: [LaneStatus]) in
            records.contains { $0.agentID == owned.agentID && $0.state != .ended }
        }
        if let host = owned.host { return hostListings[host].map { live($0.claude) } ?? false }
        if let local = localListing, live(local.claude) { return true }
        if let own = liveSelfName, let listing = hostListings[own], live(listing.claude) { return true }
        return live(statusFeed?.records ?? [])
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
            defaults.set(SharedLaneList.now(), forKey: keys.layoutChanged)
            scheduleRestoreWrite()
            sharedLanes?.localChanged()
        }
    }

    private var backends: [String: any LaneBackend] = [:]
    let defaults: UserDefaults
    private var feedSubscription: AnyCancellable?
    private var presenceSubscription: AnyCancellable?
    private var notesSubscription: AnyCancellable?
    private var usageSubscription: AnyCancellable?

    public init(configuration: Configuration, backends: [any LaneBackend],
                statusFeed: LaneStatusFeed? = LaneStatusFeed(), defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.defaultRepositoryOrder = configuration.defaultRepositoryOrder
        self.keys = AgentsModeKeys(prefix: configuration.defaultsPrefix)
        self.statusFeed = statusFeed
        self.defaults = defaults
        for backend in backends { self.backends[backend.id] = backend }
        self.selectedID = defaults.string(forKey: keys.selectedLane)
        self.showingHome = configuration.showsHome && defaults.bool(forKey: keys.showingHome)
        if configuration.showsHome, configuration.opensActiveOnly { defaults.set(true, forKey: keys.filterOpen) }
        liveSnapshot = configuration.liveSnapshotFile.flatMap { LiveSessionSnapshot.load($0) }
        liveSnapshotRead = liveSnapshot != nil
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
        startSessionOwnership()
        startDisplayedExport()
        if statusFeed != nil { startTranscripts() }
        if configuration.showsRowMetadata { startRowMetadata() }
        if configuration.notifies { notifier = LaneNotifier(store: self) }
        startSummaries()
        startPullRequestLedger()
        if !configuration.usageSources.isEmpty {
            let model = AgentUsageModel(sources: configuration.usageSources)
            usage = model
            // Menus that say which agent a new session starts on follow the figures.
            usageSubscription = model.$usages.dropFirst().removeDuplicates().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
        }
        if configuration.findsDetachedSessions { startDiscovery() }
        if let settings = configuration.sharedLanes, let resolved = settings.resolve() {
            agentHosts = resolved.hosts
            sharedLanes = SharedLaneSync(store: self, transport: resolved.transport, cacheFile: settings.cacheFile,
                                       restores: settings.restores)
            // An app that never calls restoreAtLaunch() or performLaunchBehavior(),
            // or is reopened hidden, still mirrors its rows: sync starts a few
            // seconds after launch whether or not the app is frontmost.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sharedLanesStartDelay) { [weak self] in
                MainActor.assumeIsolated { self?.sharedLanes?.start() }
            }
        }
        if configuration.hostSessions != nil { startHostListing() }
        startLaneRequests()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // Terminals ending as the app quits are not the person closing
            // them; the app's own saveRestore() records what was open.
            MainActor.assumeIsolated { self?.freezeRestore() }
        }
    }

    private var terminationObserver: NSObjectProtocol?
    /// Watches for ``LaneRequest``s from other processes.
    var laneRequestObserver: NSObjectProtocol?

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

    /// The dialogs a lane's menu asks for. One for the store, so the menu bar
    /// and every row's menu ask through the same ones.
    let menus = LaneMenuPresentation()

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
                    session?.subtitle ?? "", session?.summary ?? ""]
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

    var notifier: LaneNotifier?
    /// Which app the person last worked in for each session, when configured.
    var ownership: SessionOwnership?
    /// Set while the store opens a lane the person did not ask for, as at launch.
    var suppressOwnerClaim = false
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
        // A session another app owns is shown and badged nowhere here: the
        // app the person last worked in for it speaks for it.
        if !lookingAtIt, shouldNotify(for: session) { notifier?.post(for: session) }
        updateBadge()
    }

    /// The number the Dock badge shows: the unread rows of the list the
    /// sidebar draws, the same ones its Unread filter counts.
    private(set) var badgeCount = 0

    /// Set the Dock badge from the rows now shown. It runs whenever a row's
    /// unread mark changes and whenever a row goes, so a badge never outlives
    /// the row that asked for it.
    func updateBadge() {
        // From the lanes themselves, not the cached list, which may not have
        // caught up with a change that has just been made.
        let count = listedLanes.filter { lane in
            guard let session = sessions[lane.id], session.needsAttention else { return false }
            return ownsSession(session)
        }.count
        badgeCount = count
        guard configuration.notifies, LaneNotifier.isAvailable else { return }
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

    /// The lanes the list shows: every lane but the accessory lanes.
    public var listedLanes: [AgentLane] { lanes.filter { $0.accessory == nil } }
    /// The lanes reached from a filter-bar button, in the order given.
    public var accessoryLanes: [AgentLane] { lanes.filter { $0.accessory != nil } }

    /// Whether the accessory lane `id` is what the detail pane shows.
    public func isShowingAccessory(_ id: AgentLane.ID) -> Bool { !isHomeShown && selectedID == id }

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
        // An app brings its rows (and with them the folders its scope
        // admits) after launch, so a sweep that ran before they came saw
        // sessions the scope kept out. Sweep again for rows it has not seen.
        let addedRows = !ids.isSubset(of: Set(lanes.map(\.id)))
        for (id, session) in sessions where !ids.contains(id) {
            session.detach()
            sessions.removeValue(forKey: id)
        }
        lanes = newLanes
        for lane in newLanes { makeSession(for: lane) }
        if splitID.map({ !ids.contains($0) }) ?? false { splitID = nil }
        if selectedID.map({ !ids.contains($0) }) ?? true {
            selectedID = (newLanes.first { $0.accessory == nil } ?? newLanes.first)?.id
        }
        apply(statusFeed?.records ?? [])
        reconcileDetached()
        if addedRows, configuration.findsDetachedSessions { sweepSoon() }
    }

    /// Add a lane the person opened, and open it.
    @discardableResult
    public func add(_ lane: AgentLane, focus: Bool = true, open shouldOpen: Bool = true,
                    after anchor: AgentLane.ID? = nil) -> AgentLaneSession? {
        if sessions[lane.id] == nil {
            if let anchor, let index = lanes.firstIndex(where: { $0.id == anchor }) {
                lanes.insert(lane, at: index + 1)
                let ordered = layout.orderedIDs(orderedLanes)
                if let at = ordered.firstIndex(of: anchor), at + 1 < ordered.count, ordered[at + 1] != lane.id {
                    layout.moveLane(lane.id, before: ordered[at + 1], lanes: orderedLanes)
                }
            } else {
                lanes.append(lane)
            }
            makeSession(for: lane)
            syncSessionHolders()
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
            let wrapper = wrapperCommand(for: lane)
            return LaneWorkspace.Lane(title: layout.names[lane.id],
                                      directory: sessions[lane.id]?.currentDirectory ?? lane.directory?.path,
                                      backendID: lane.backendID,
                                      section: layout.section(of: lane),
                                      pinned: layout.pinned.contains(lane.id) ? true : nil,
                                      variant: lane.variant, sessionName: lane.sessionName,
                                      agentSessionID: lane.agentSessionID,
                                      agentConversationID: lane.agentConversationID,
                                      selected: marksSelection && lane.id == selectedID ? true : nil,
                                      id: lane.id, host: lane.host,
                                      command: wrapper?.command, variantFlag: wrapper?.variantFlag)
        }
        let used = Set(lanes.compactMap(\.section))
        return LaneWorkspace(name: name, sections: layout.orderedSections(for: orderedLanes).filter { used.contains($0) || layout.sections.contains($0) },
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

    /// Add a workspace's lanes, each under the id it was saved with, skipping
    /// any whose id is already open; so two lanes in one folder both come
    /// back. A lane saved before ids were kept is skipped when one is open in
    /// the same folder on the same backend, and gets a new id. They wait
    /// until shown, apart from the first.
    public func open(workspace: LaneWorkspace, resume: Bool = false) {
        for name in workspace.sections { layout.addSection(name) }
        var first: AgentLane.ID?
        var chosen: AgentLane.ID?
        for saved in workspace.lanes {
            guard let id = addSaved(saved, resume: resume) else { continue }
            if first == nil { first = id }
            if saved.selected == true { chosen = id }
        }
        if let pick = chosen ?? first, selected?.lane.isClosable != true { selectedID = pick }
    }

    /// Add one saved lane without showing it, returning its id, or nil when
    /// it is already open.
    @discardableResult
    func addSaved(_ saved: LaneWorkspace.Lane, resume: Bool) -> AgentLane.ID? {
        let path = saved.directory.map { ($0 as NSString).expandingTildeInPath }
        if let scope = configuration.sessionScope, !scope(path, saved.host) { return nil }
        let already: Bool
        if let id = saved.id {
            already = lanes.contains { $0.id == id }
        } else {
            already = lanes.contains { lane in
                guard !detachedIDs.contains(lane.id), lane.backendID == saved.backendID else { return false }
                if let name = saved.sessionName ?? lane.sessionName { return name == lane.sessionName && name == saved.sessionName }
                return lane.variant == saved.variant
                    && path.map { LaneStatusMatch.normalizedPath($0) == LaneStatusMatch.normalizedPath(lane.path) } ?? false
            }
        }
        if already { return nil }
        var lane = AgentLane(id: saved.id ?? UUID().uuidString,
                             title: saved.sessionName ?? (path as NSString?)?.lastPathComponent ?? "Lane",
                             directory: path.map { URL(fileURLWithPath: $0, isDirectory: true) },
                             backendID: saved.backendID, isClosable: true, section: saved.section)
        lane.variant = saved.variant
        lane.sessionName = saved.sessionName
        lane.agentSessionID = saved.agentSessionID
        lane.agentConversationID = saved.agentConversationID
        // A background row made from a session is that session: a saved id
        // that is another session's is stale, and goes before any attach.
        if let own = DetachedSessions.ownAgentID(ofLaneID: lane.id), lane.agentSessionID != own {
            lane.agentSessionID = own
            lane.agentConversationID = nil
        }
        lane.host = saved.host
        // A session the restore brings back attaches here, so its
        // Detached row (if the sweep already found it) goes.
        if let name = saved.sessionName,
           let row = lanes.first(where: { row in
               guard detachedIDs.contains(row.id), row.backendID == saved.backendID, row.sessionName == name else { return false }
               guard let id = saved.agentSessionID, let held = row.agentSessionID else { return true }
               return DetachedSessions.sameSession(id, held)
           }),
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
        return lane.id
    }

    /// The wrapper a lane runs, when its backend is a ``CommandLaneBackend``
    /// that passes the folder.
    func wrapperCommand(for lane: AgentLane) -> (command: String, variantFlag: String?)? {
        guard let backend = backends[lane.backendID] as? CommandLaneBackend, backend.passesDirectory else { return nil }
        let command = backend.command.trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? nil : (command, backend.variantFlag)
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

    // MARK: Shared lanes and hosts

    /// How long after launch sharing starts if nothing started it sooner.
    nonisolated(unsafe) static var sharedLanesStartDelay: TimeInterval = 5

    /// The hosts registry (``AgentHosts``), when this Mac has one.
    @Published public private(set) var agentHosts: AgentHosts?
    /// Keeps the lane list in step with the hub's; nil without the registry.
    var sharedLanes: SharedLaneSync?

    /// The hosts Run On offers for a lane: the hub, then every lane host.
    /// Empty without a registry, and for a lane whose backend is not a lane
    /// wrapper that reads the host from its environment.
    public func runOnHosts(for id: AgentLane.ID) -> [AgentHosts.Host] {
        guard let hosts = agentHosts, let lane = lanes.first(where: { $0.id == id }), lane.isClosable,
              !detachedIDs.contains(id), let backend = backends[lane.backendID] as? CommandLaneBackend,
              backend.passesDirectory, backend.tmuxSessions?.host == nil else { return [] }
        return hosts.laneHosts
    }

    /// The host a lane runs on: its own, else the hub.
    public func host(of id: AgentLane.ID) -> String? {
        lanes.first { $0.id == id }?.host ?? agentHosts?.hub?.name
    }

    /// Run a lane on `host` from now on, restarting its terminal when it is
    /// attached so the wrapper starts there. The hub is recorded as no host.
    public func setHost(_ id: AgentLane.ID, to host: String?, reattach shouldReattach: Bool = true) {
        guard let index = lanes.firstIndex(where: { $0.id == id }), lanes[index].isClosable else { return }
        let value = host.flatMap { $0.isEmpty || $0 == agentHosts?.hub?.name ? nil : $0 }
        guard lanes[index].host != value else { return }
        lanes[index].host = value
        guard let session = sessions[id] else { return }
        session.update(lane: lanes[index])
        if shouldReattach, session.isAttached { reattach(id) }
    }

    /// When this Mac last changed how its lanes are laid out, to the second.
    var layoutEditedAt: Date? { defaults.object(forKey: keys.layoutChanged) as? Date }

    /// The listed rows this Mac has styled or taken a style for, so it can
    /// tell the others when the style is cleared.
    private var styledOverlays: Set<AgentLane.ID> = []

    /// Whether the person gave a row a name, icon, colour, pin or section.
    private func isStyled(_ id: AgentLane.ID) -> Bool {
        layout.names[id] != nil || layout.icons[id] != nil || layout.tints[id] != nil
            || layout.pinned.contains(id) || layout.assignments[id] != nil
    }

    /// The lanes the person opened, as the shared list records them, in
    /// list order, and after them the rows the app lists itself that the
    /// person named, pinned, coloured or filed (`overlay` entries, which
    /// never make a row on another Mac). `updated` is left for the sync.
    func sharedLaneEntries() -> [SharedLaneList.Lane] {
        var entries: [SharedLaneList.Lane] = []
        for (order, lane) in displayOrder.enumerated() {
            if lane.isClosable && !detachedIDs.contains(lane.id) {
                let wrapper = wrapperCommand(for: lane)
                entries.append(SharedLaneList.Lane(
                    id: lane.id, title: layout.names[lane.id],
                    directory: lane.directory.map { SharedLaneList.tildePath($0.path) },
                    backendID: lane.backendID, command: wrapper?.command,
                    variantFlag: wrapper?.variantFlag, variant: lane.variant, host: lane.host,
                    section: layout.section(of: lane),
                    pinned: layout.pinned.contains(lane.id) ? true : nil,
                    icon: layout.icons[lane.id], tint: layout.tints[lane.id],
                    sessionName: lane.sessionName, agentSessionID: lane.agentSessionID,
                    order: order, updated: .distantPast))
            } else if isStyled(lane.id) || styledOverlays.contains(lane.id) {
                // A row this Mac styled and has since cleared still gets an
                // entry, a bare one, so the clearing reaches the other Macs.
                styledOverlays.insert(lane.id)
                entries.append(SharedLaneList.Lane(
                    id: lane.id, title: layout.names[lane.id], backendID: lane.backendID,
                    section: layout.assignments[lane.id].flatMap { $0.isEmpty ? nil : $0 },
                    pinned: layout.pinned.contains(lane.id) ? true : nil,
                    icon: layout.icons[lane.id], tint: layout.tints[lane.id], overlay: true,
                    order: order, updated: .distantPast))
            }
        }
        return entries
    }

    /// Bring the sidebar in line with a merged list: add the lanes another
    /// Mac opened, take away the ones closed elsewhere (their sessions keep
    /// running), and take names, icons, moves, pins, hosts and order made
    /// elsewhere. It only changes rows and how they are listed: it never
    /// starts, attaches, stops or renames a session. `captured` is what
    /// this Mac had when the sync began; a lane changed here since is left
    /// alone, and so are the `skipping` ids.
    func applyShared(_ list: SharedLaneList, captured: [SharedLaneList.Lane], skipping: Set<String>) {
        let before = Dictionary(captured.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var current = Dictionary(sharedLaneEntries().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = Set(list.lanes.map(\.id))
        for close in list.closed where !live.contains(close.id) && current[close.id]?.overlay != true && current[close.id] != nil {
            removeSharedLane(close.id)
            current.removeValue(forKey: close.id)
        }
        for entry in list.lanes where !skipping.contains(entry.id) {
            if entry.overlay == true {
                applyOverlay(entry, before: before[entry.id], now: current[entry.id])
            } else if let now = current[entry.id], now.overlay != true {
                guard let then = before[entry.id], then.sameContent(as: now), !entry.sameContent(as: now) else { continue }
                applyStyle(entry, now: now)
                if entry.host != now.host { setHost(entry.id, to: entry.host, reattach: false) }
            } else if detachedIDs.contains(entry.id) {
                // Adopted on another Mac: adopt it here, without attaching.
                adopt(entry.id, into: entry.section, attach: false)
                applyStyle(entry, now: nil)
            } else if !lanes.contains(where: { $0.id == entry.id }), backends[entry.backendID] != nil {
                addSaved(LaneWorkspace.Lane(title: entry.title, directory: entry.directory, backendID: entry.backendID,
                                            section: entry.section, pinned: entry.pinned, variant: entry.variant,
                                            sessionName: entry.sessionName, agentSessionID: entry.agentSessionID,
                                            id: entry.id, host: entry.host),
                         resume: true)
                applyStyle(entry, now: nil)
            }
        }
        applySharedOrder(list, captured: captured)
    }

    /// Take the name, icon, colour, section and pin an entry carries,
    /// where they differ from `now` (the row as it stands, nil for none).
    private func applyStyle(_ entry: SharedLaneList.Lane, now: SharedLaneList.Lane?) {
        if entry.title != now?.title, entry.title != nil || now != nil { setName(entry.id, to: entry.title) }
        if entry.section != now?.section, now != nil { layout.move(entry.id, to: entry.section) }
        if (entry.pinned == true) != (now?.pinned == true) { layout.setPinned(entry.id, entry.pinned == true) }
        if entry.icon != now?.icon || entry.tint != now?.tint {
            setIcon(entry.icon.flatMap(LaneIcon.init), tint: entry.tint, for: entry.id)
        }
    }

    /// An entry that only styles a row this Mac lists itself. A row not
    /// listed here is left for later, and one styled here since the sync
    /// began keeps what it has.
    private func applyOverlay(_ entry: SharedLaneList.Lane, before: SharedLaneList.Lane?, now: SharedLaneList.Lane?) {
        guard lanes.contains(where: { $0.id == entry.id }) else { return }
        let unchanged: Bool
        switch (before, now) {
        case (nil, nil): unchanged = true
        case (let then?, let current?): unchanged = then.sameContent(as: current)
        default: unchanged = false
        }
        guard unchanged, now.map({ !entry.sameContent(as: $0) }) ?? true else { return }
        let had = now ?? SharedLaneList.Lane(id: entry.id, backendID: entry.backendID, overlay: true)
        if entry.title != had.title { setName(entry.id, to: entry.title) }
        if let section = entry.section, section != had.section { layout.move(entry.id, to: section) }
        if (entry.pinned == true) != (had.pinned == true) { layout.setPinned(entry.id, entry.pinned == true) }
        if entry.icon != had.icon || entry.tint != had.tint {
            setIcon(entry.icon.flatMap(LaneIcon.init), tint: entry.tint, for: entry.id)
        }
    }

    /// Put the lanes this Mac and the list both hold in the list's order,
    /// each into a place one of them already held, unless the order was
    /// changed here since the sync began.
    private func applySharedOrder(_ list: SharedLaneList, captured: [SharedLaneList.Lane]) {
        func ids(_ entries: [SharedLaneList.Lane]) -> [String] { entries.filter { $0.overlay != true }.map(\.id) }
        let local = ids(sharedLaneEntries())
        guard local == ids(captured).filter(Set(local).contains) else { return }
        let held = Set(local)
        let wanted = ids(list.lanes).filter(held.contains)
        guard wanted.count == local.count, wanted != local else { return }
        var all = layout.orderedIDs(orderedLanes)
        var next = wanted.makeIterator()
        for index in all.indices where held.contains(all[index]) { all[index] = next.next() ?? all[index] }
        layout.order = all
    }

    /// Take a lane closed on another Mac out of the sidebar. Only the
    /// terminal here ends; its session is never stopped.
    func removeSharedLane(_ id: AgentLane.ID) {
        guard let index = lanes.firstIndex(where: { $0.id == id }), lanes[index].isClosable else { return }
        restoredPending.remove(id)
        sessions[id]?.detach()
        sessions.removeValue(forKey: id)
        lanes.remove(at: index)
        if splitID == id { splitID = nil }
        if selectedID == id {
            let neighbour = lanes.indices.contains(index) ? lanes[index] : lanes.last
            selectedID = neighbour?.id
        }
        reconcileDetached()
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
        defer {
            restoreSettled = true
            sharedLanes?.start()
        }
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
    /// each shown under the row whose folder holds it (``detachedOwners``),
    /// else in the Detached group. They are not started until the person
    /// reattaches one, are left out of the restore snapshot and workspaces,
    /// and go when their session does. ``adopt(_:into:)`` makes one a lane
    /// of the person's own.
    @Published public private(set) var detachedIDs: Set<AgentLane.ID> = []

    /// Whether a row is a found session no row of the person's or the
    /// app's attaches, wherever the list shows it.
    public func isDetached(_ id: AgentLane.ID) -> Bool { detachedIDs.contains(id) }

    /// The row each found session is listed under, by the found row's id:
    /// the row whose folder holds the session's
    /// (``DetachedSessions/owner(of:among:backends:normalize:)``). A found
    /// row missing here is in the Detached group.
    @Published public private(set) var detachedOwners: [AgentLane.ID: AgentLane.ID] = [:]
    /// Paths as compared, kept because resolving one reads the disk.
    private var normalizedPaths: [String: String] = [:]
    /// The session ids the status feed showed last, to sweep again soon
    /// after one starts or ends rather than at the next ten-minute ask.
    private var seenStatusSessionIDs: Set<String> = []
    private(set) var lastSweep = Date.distantPast
    /// The first sweep since launch has come back. Later sweeps refresh the
    /// list quietly, so they never put the rows back into a loading state.
    @Published private(set) var firstSweepFinished = false
    /// The shortest wait between sweeps the status feed asks for.
    static let liveSweepSpacing: TimeInterval = 20

    /// How often backends are asked for their sessions after launch. Each
    /// ask is at most one helper process per backend, one at a time.
    static let discoveryInterval: TimeInterval = 600
    /// How long after launch (or a backend registering) the first ask
    /// waits, so the app's own lanes and the restore are in first.
    static let firstDiscoveryDelay: TimeInterval = 0.5

    private var discoveryTimer: CadenceTimer?
    var sweepScheduled: Bool { discoveryKick != nil }
    private var discoveryKick: Task<Void, Never>?
    @Published private(set) var sweepingSessions = false
    /// Everything the last sweep found, kept so rows added later can claim
    /// their sessions without asking the backends again.
    private var discovered: [DetachedSessions.Found] = []
    /// The agent session ids each row holds, as of the last status update,
    /// so a session a row attaches leaves Detached whatever it is named.
    private var heldSessionIDs: [AgentLane.ID: [String]] = [:]
    /// The Claude session each row owns by the bindings, by short id
    /// (``ownedSession(for:)``), as of the last status update. An owned
    /// session is the row's own and never also a found row.
    private(set) var ownedSessionIDs: [AgentLane.ID: DetachedSessions.OwnedSession] = [:]

    private func startDiscovery() {
        discoveryTimer = CadenceTimer(interval: Self.discoveryInterval) { [weak self] in
            self?.sweepForDetachedSessions()
        }
        sweepSoon()
    }

    /// One sweep a moment from now, however many times this is called, and
    /// no sooner than ``liveSweepSpacing`` after the last.
    private func sweepSoon() {
        guard discoveryKick == nil else { return }
        let wait = max(Self.firstDiscoveryDelay, Self.liveSweepSpacing - Date().timeIntervalSince(lastSweep))
        discoveryKick = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.discoveryKick = nil
            self.sweepForDetachedSessions()
        }
    }

    /// Ask every backend for its lane sessions now and update the Detached
    /// section. Skipped while the last sweep is still going.
    public func sweepForDetachedSessions() {
        guard configuration.findsDetachedSessions, !sweepingSessions else { return }
        seedFoundFromLiveSnapshot()
        sweepingSessions = true
        lastSweep = Date()
        refreshHostListingSoon()
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
            self.firstSweepFinished = true
            self.lastDiscoveryFinishedAt = Date()
            self.received(found: found)
            self.displayedExporter?.changed()
        }
    }

    /// Take what a sweep found and match it against the rows.
    func received(found: [DetachedSessions.Found]) {
        discovered = found
        reconcileDetached()
        retireLiveHints()
    }

    // MARK: Live snapshot

    /// What the outside watcher last wrote (``Configuration/liveSnapshotFile``),
    /// read at launch; nil once nothing from it is still on show.
    private(set) var liveSnapshot: LiveSessionSnapshot?
    /// The search text the sidebar and All Agents show, told by their views
    /// for the displayed export.
    var displayedSidebarSearch = "" {
        didSet { if displayedSidebarSearch != oldValue { displayedExporter?.changed() } }
    }
    var displayedHomeSearch = "" {
        didSet { if displayedHomeSearch != oldValue { displayedExporter?.changed() } }
    }
    /// When the last sweep for sessions came back.
    var lastDiscoveryFinishedAt: Date?
    var displayedExporter: DisplayedExporter?
    private(set) var liveSnapshotRead = false
    private var liveFoundSeeded = false

    /// The host a lane's session runs on, as the snapshot names hosts: the
    /// lane's session host when the hosts registry is known, else this Mac.
    func liveHost(for lane: AgentLane) -> String? {
        sessionHost(for: lane) ?? liveSelfName
    }

    /// This Mac's name in the hosts registry, as the snapshot lists it.
    var liveSelfName: String? {
        liveSelfNameOverride ?? (listingHosts ?? configuration.hostSessions?.hosts ?? agentHosts ?? AgentHosts.load())?.selfName
    }
    /// For tests: this Mac's name without a hosts registry.
    var liveSelfNameOverride: String?

    /// Before the first sweep comes back, show the found sessions the
    /// snapshot lists on this Mac, in the app's scope, as the sweep will.
    /// Their rows have the ids the sweep's would, so they stay when it
    /// confirms them and go when it does not.
    private func seedFoundFromLiveSnapshot() {
        guard !liveFoundSeeded, !firstSweepFinished, discovered.isEmpty, let snapshot = liveSnapshot else { return }
        liveFoundSeeded = true
        let found = LiveSnapshotSeed.found(in: snapshot, selfName: liveSelfName,
                                           backends: availableBackends, scope: configuration.sessionScope)
        guard !found.isEmpty else { return }
        discovered = found
        reconcileDetached()
    }

    /// Settle each hint once its host has said what it runs. On this Mac
    /// the first sweep and the status feed take over, so the hint goes. For
    /// another host, its listing decides: a session it still lists keeps its
    /// hint, now current, and one it no longer lists loses it. A host that did
    /// not answer keeps its hints, marked stale, with when it was last seen.
    func retireLiveHints() {
        guard liveSnapshot != nil else { return }
        let selfName = liveSelfName
        var standing = false
        for session in sessions.values {
            guard var hint = session.liveHint else { continue }
            guard let host = hint.host, host != selfName, configuration.hostSessions != nil,
                  let hosts = listingHosts, HostSessions.askedHosts(hosts).contains(where: { $0.name == host }) else {
                if firstSweepFinished { session.liveHint = nil } else { standing = true }
                continue
            }
            if unknownHosts.contains(host) {
                if !hint.isStale { hint.isStale = true; session.liveHint = hint }
                standing = true
            } else if let listing = hostListings[host] {
                if hint.isListed(in: listing) {
                    if hint.isStale { hint.isStale = false; session.liveHint = hint }
                    standing = true
                } else {
                    session.liveHint = nil
                }
            } else {
                standing = true
            }
        }
        if !standing, firstSweepFinished { liveSnapshot = nil }
        objectWillChange.send()
    }

    /// Match the last sweep against the rows: add a Detached row for each
    /// session nothing attaches, and take away rows whose session has gone
    /// or now has a row of its own, unless they are attached here.
    private func reconcileDetached() {
        guard configuration.findsDetachedSessions else { return }
        let rows = lanes.filter { !detachedIDs.contains($0.id) }
        let inScope = configuration.sessionScope.map { scope in
            discovered.filter { scope($0.session.directory, $0.session.host) }
        } ?? discovered
        let wanted = DetachedSessions.unclaimed(inScope, lanes: rows, backends: backends, heldSessionIDs: heldSessionIDs,
                                                ownedSessionIDs: ownedSessionIDs)
        let wantedIDs = Set(wanted.map(DetachedSessions.laneID))
        for id in detachedIDs where !wantedIDs.contains(id) && sessions[id]?.isAttached != true {
            removeDetachedRow(id)
        }
        let shared = DetachedSessions.sharedNames(wanted)
        // Until the hosts first say which lane owns which session, a found
        // row is not added: it could be a lane's own, and would go again.
        for found in wanted where backends[found.backendID] != nil
            && (!awaitingBindings(for: found) || lanes.contains { $0.id == DetachedSessions.laneID(found) }) {
            let lane = DetachedSessions.lane(for: found, sharesName: DetachedSessions.sharesName(found, in: shared))
            if let index = lanes.firstIndex(where: { $0.id == lane.id }) {
                // A name another session took or gave up since the row was made.
                if detachedIDs.contains(lane.id), lanes[index].title != lane.title {
                    lanes[index].title = lane.title
                    sessions[lane.id]?.update(lane: lanes[index])
                }
                continue
            }
            guard !detachedIDs.contains(lane.id) else { continue }
            detachedIDs.insert(lane.id)
            lanes.append(lane)
            makeSession(for: lane)
        }
        placeDetached()
        apply(statusFeed?.records ?? [])
        if let presence = statusFeed?.presence { apply(presence: presence) }
    }

    /// Work out which row each found session is listed under. A found row
    /// whose session the last sweep no longer lists (one attached here)
    /// keeps the row it had.
    private func placeDetached() {
        guard configuration.placesDetachedSessions, !detachedIDs.isEmpty else {
            if !detachedOwners.isEmpty { detachedOwners = [:] }
            return
        }
        let rows = lanes.filter { !detachedIDs.contains($0.id) }
        var found: [AgentLane.ID: DetachedSessions.Found] = [:]
        for item in discovered { found[DetachedSessions.laneID(item)] = found[DetachedSessions.laneID(item)] ?? item }
        let rowIDs = Set(rows.map(\.id))
        var owners: [AgentLane.ID: AgentLane.ID] = [:]
        for id in detachedIDs {
            if let item = found[id] {
                owners[id] = DetachedSessions.owner(of: item.session, among: rows, backends: backends,
                                                    normalize: normalizedPath)
            } else if let kept = detachedOwners[id], rowIDs.contains(kept) {
                owners[id] = kept
            }
        }
        if owners != detachedOwners { detachedOwners = owners }
    }

    private func normalizedPath(_ path: String) -> String {
        if let known = normalizedPaths[path] { return known }
        let normalized = LaneStatusMatch.normalizedPath(path)
        normalizedPaths[path] = normalized
        return normalized
    }

    /// Sweep soon when the status feed shows a session no row holds and the
    /// last sweep did not find, or loses one the last sweep found, so a
    /// session started or ended elsewhere shows up or goes within seconds.
    private func noticeStatusSessions(_ records: [LaneStatus]) {
        guard configuration.findsDetachedSessions else { return }
        let ids = Set(records.compactMap(\.sessionID).filter { !$0.isEmpty })
        guard ids != seenStatusSessionIDs else { return }
        let fresh = ids.subtracting(seenStatusSessionIDs), gone = seenStatusSessionIDs.subtracting(ids)
        seenStatusSessionIDs = ids
        let found = discovered.compactMap(\.session.sessionID)
        let held = heldSessionIDs.values.flatMap { $0 }
        func known(_ id: String) -> Bool {
            found.contains { DetachedSessions.sameSession(id, $0) } || held.contains { DetachedSessions.sameSession(id, $0) }
        }
        let started = fresh.contains { !known($0) }
        let ended = gone.contains { id in found.contains { DetachedSessions.sameSession(id, $0) } }
        if started || ended { sweepSoon() }
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
    public func adopt(_ id: AgentLane.ID, into section: String?, attach: Bool = true) {
        guard detachedIDs.contains(id), let index = lanes.firstIndex(where: { $0.id == id }),
              let session = sessions[id] else { return }
        detachedIDs.remove(id)
        var lane = lanes[index]
        lane.isClosable = true
        lane.section = section
        // A session found on another machine keeps running there; the row
        // records where, so a Mac that shares the row reaches it the same way.
        if lane.host == nil, let found = discovered.first(where: { DetachedSessions.laneID($0) == id }),
           let host = found.session.host, host != agentHosts?.selfName {
            lane.host = host
        }
        lanes[index] = lane
        session.update(lane: lane)
        layout.move(id, to: section)
        if attach { attachInBackground(id) }
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
        firstShowPending = false
        launchAttachPending = nil
        if lanes.isEmpty { openNewLane(in: newLaneDirectory) } else if !isHomeShown { openSelected(focus: true) }
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

    /// Agents mode for an app that shows its lanes in ``AgentLaneDock``: the
    /// dock open and filling the window. Unlike ``showDock(newLaneDirectory:)``
    /// it starts nothing: no new lane, and the terminal area shows the
    /// selected lane only if its session is already running.
    public func enterAgentsMode() {
        if !dockVisible {
            focusBeforeDock = NSApp.keyWindow?.firstResponder
            dockVisible = true
        }
        dockMaximized = true
    }

    /// Until the lanes have been on screen once, showing them starts no
    /// session: launch opens Agents mode without running an agent anyone
    /// did not ask for.
    private(set) var firstShowPending = true

    /// Show the selected lane's terminal as the lanes come on screen. The
    /// first time after launch, that is only a lane whose session already
    /// runs: one attached here is shown as it is, and one not attached is
    /// attached only when its backend keeps sessions running detached, a
    /// presence source lists the session under the lane's own tmux name
    /// (never a session that merely shares its folder), and the backend has
    /// an attach-only launch for it (``LaneBackend/attachLaunch(for:shell:)``).
    /// That launch never resumes or starts anything; if the session has gone
    /// the row shows Reattach. Nothing is created, and nothing new is started.
    ///
    /// With Home on and ``Configuration/launchShows`` at its default, the
    /// first show is Home instead, and nothing is attached until the person
    /// picks a row. While Home is showing, showing the lanes again leaves it.
    public func openSelectedOnShow(focus: Bool = true) {
        guard firstShowPending else {
            if isHomeShown { return }
            // Showing the lanes again is not the person working in the selected one.
            let before = suppressOwnerClaim
            suppressOwnerClaim = true
            defer { suppressOwnerClaim = before }
            return openSelected(focus: focus)
        }
        firstShowPending = false
        if configuration.showsHome, configuration.launchShows == .home {
            showingHome = true
            return
        }
        // Home left showing at quit comes back as it was.
        if isHomeShown { return }
        guard let id = selectedID, let session = sessions[id] else { return }
        if session.isAttached {
            if focus { session.wantsFocus = true }
            updateShown()
        } else if session.backend.keepsRunningWhenDetached, let name = session.presenceName,
                  let attach = session.backend.attachLaunch(for: session.lane, sessionName: name,
                                                            shell: AgentLaneSession.loginShell) {
            attachOnly(id, with: attach, focus: focus)
        } else if configuration.hostSessions != nil {
            launchAttachPending = id
            attachPendingFromHosts()
        }
    }

    private func attachOnly(_ id: AgentLane.ID, with launch: TerminalLaunch, focus: Bool) {
        guard let session = sessions[id] else { return }
        session.resumeOnStart = false
        session.attachOnlyLaunch = launch
        // Reattaching what was open at launch is not the person working in it.
        let before = suppressOwnerClaim
        suppressOwnerClaim = true
        open(id, focus: focus)
        suppressOwnerClaim = before
    }

    // MARK: Lane hosts

    /// What each lane host had running when asked at launch, by host name.
    @Published public private(set) var hostListings: [String: HostSessionListing] = [:]
    /// Lane hosts that did not answer: their sessions are unknown, not gone.
    @Published public private(set) var unknownHosts: Set<String> = []
    /// The lane launch shows, waiting for its host to answer so its session
    /// can be attached. Cleared when anything else opens a lane.
    @Published private(set) var launchAttachPending: AgentLane.ID?
    private(set) var listingHosts: AgentHosts?

    /// What this Mac had running, when the app gives no hosts registry: the
    /// bindings command run here, for the lanes that run here.
    private(set) var localListing: HostSessionListing?
    /// Hosts asked and not yet answered, by name ("" is this Mac with no
    /// registry), so an ask still going is not started again.
    private var hostAsksGoing: Set<String> = []
    /// True from the first ask until every host asked has answered or timed
    /// out once. Until then a sweep adds no found rows, so a session a lane
    /// turns out to own is never shown apart and then taken away.
    private(set) var awaitingFirstBindings = false
    private var lastHostAsk = Date.distantPast
    /// The shortest wait between asks after the first, so a busy status
    /// feed does not run the listing on every host each sweep.
    static let hostAskSpacing: TimeInterval = 60
    /// The last bindings each host gave that were known, by host name ("" is
    /// this Mac with no registry). Kept when a later ask fails, so a lane's
    /// ownership does not come and go with one host's answer.
    private var knownBindings: [String: [String: String]] = [:]

    /// Ask every hub and lane host in the registry what it has running, or
    /// only this Mac when there is no registry.
    private func startHostListing() {
        guard let config = configuration.hostSessions else { return }
        lastHostAsk = Date()
        guard let hosts = config.hosts ?? agentHosts ?? AgentHosts.load() else {
            guard config.bindingsCommand?.isEmpty == false, hostAsksGoing.insert("").inserted else { return }
            if localListing == nil { awaitingFirstBindings = true }
            Task { @MainActor [weak self] in
                let listing = await HostSessions.list(host: nil, config: config)
                self?.receivedLocal(listing)
            }
            return
        }
        listingHosts = hosts
        let asked = HostSessions.askedHosts(hosts).filter { hostAsksGoing.insert($0.name).inserted }
        if !asked.isEmpty, hostListings.isEmpty, unknownHosts.isEmpty { awaitingFirstBindings = true }
        for host in asked {
            let name = host.name, local = name == hosts.selfName
            Task { @MainActor [weak self] in
                let listing = await HostSessions.list(host: local ? nil : name, config: config)
                self?.received(listing, from: name)
            }
        }
    }

    /// Whether a found session's host has yet to say which lane owns it. Only
    /// that host holds its rows back, so a slow or offline Mac delays no other.
    private func awaitingBindings(for found: DetachedSessions.Found) -> Bool {
        guard awaitingFirstBindings else { return false }
        guard let hosts = listingHosts else { return true }
        return hostAsksGoing.contains(found.session.host ?? hosts.selfName)
    }

    /// Ask one host again, after it did not answer. Its rows go back to
    /// checking until it does.
    public func retryHost(_ name: String) {
        guard let config = configuration.hostSessions, let hosts = listingHosts,
              HostSessions.askedHosts(hosts).contains(where: { $0.name == name }),
              hostAsksGoing.insert(name).inserted else { return }
        unknownHosts.remove(name)
        let local = name == hosts.selfName
        Task { @MainActor [weak self] in
            let listing = await HostSessions.list(host: local ? nil : name, config: config)
            self?.received(listing, from: name)
        }
    }

    /// Ask the hosts again, when the last ask is ``hostAskSpacing`` old, so
    /// bindings made since launch are seen.
    private func refreshHostListingSoon() {
        guard configuration.hostSessions != nil, Date().timeIntervalSince(lastHostAsk) >= Self.hostAskSpacing else { return }
        startHostListing()
    }

    /// Record one host's answer, nil when it did not give one.
    func received(_ listing: HostSessionListing?, from host: String, hosts: AgentHosts? = nil) {
        if let hosts { listingHosts = hosts }
        hostAsksGoing.remove(host)
        if let listing {
            hostListings[host] = listing
            unknownHosts.remove(host)
            if listing.bindingsKnown { knownBindings[host] = listing.bindings }
        } else {
            hostListings[host] = nil
            unknownHosts.insert(host)
        }
        attachPendingFromHosts()
        bindingsChanged()
        retireLiveHints()
    }

    /// Record this Mac's answer when there is no hosts registry.
    func receivedLocal(_ listing: HostSessionListing?) {
        hostAsksGoing.remove("")
        localListing = listing ?? localListing
        if let listing, listing.bindingsKnown { knownBindings[""] = listing.bindings }
        bindingsChanged()
    }

    /// Match status and found sessions again with what the hosts said.
    private func bindingsChanged() {
        if awaitingFirstBindings, hostAsksGoing.isEmpty { awaitingFirstBindings = false }
        apply(statusFeed?.records ?? [])
        reconcileDetached()
    }

    /// The Claude background session a lane owns by the bindings
    /// (``HostSessionsConfiguration/bindingsCommand``): its exact short id,
    /// on the host its session runs on (nil for this Mac). With no hosts
    /// registry, only a lane that runs here, on this Mac. Nil when the lane
    /// has no binding, or when its host's bindings have never been known.
    func ownedSession(for lane: AgentLane) -> DetachedSessions.OwnedSession? {
        guard let config = configuration.hostSessions, config.bindingsCommand?.isEmpty == false,
              !detachedIDs.contains(lane.id) else { return nil }
        let host: String
        if let hosts = listingHosts {
            guard let found = sessionHost(for: lane) else { return nil }
            host = found
            guard let id = knownBindings[host]?[config.bindingKey(lane)], HostSessions.isValidAgentID(id) else { return nil }
            return .init(host: host == hosts.selfName ? nil : host, agentID: id)
        } else {
            guard lane.host == nil, let backend = backends[lane.backendID], DetachedSessions.laneHost(backend) == nil
            else { return nil }
            host = ""
        }
        guard let id = knownBindings[host]?[config.bindingKey(lane)], HostSessions.isValidAgentID(id) else { return nil }
        return .init(host: nil, agentID: id)
    }

    /// The host a lane's session runs on, as its backend runs it: a tmux
    /// lane backend's own host, which must be in the registry; for a lane
    /// wrapper that takes a lane's host (what Run On offers), the lane's
    /// host, else the hub; for any other backend, this Mac.
    func sessionHost(for lane: AgentLane) -> String? {
        guard let hosts = listingHosts, let backend = backends[lane.backendID] else { return nil }
        let known = Set(hosts.hosts.map(\.name))
        if let command = backend as? CommandLaneBackend {
            if let host = command.tmuxSessions?.host { return known.contains(host) ? host : nil }
            if command.passesDirectory {
                guard let host = lane.host ?? hosts.hub?.name else { return nil }
                return known.contains(host) ? host : nil
            }
        }
        return hosts.selfName
    }

    /// Attach the lane launch is waiting on, once its host has answered and
    /// lists the lane's own session exactly. An unknown host or a lane with
    /// no exact session attaches nothing.
    private func attachPendingFromHosts() {
        guard let id = launchAttachPending else { return }
        guard selectedID == id, let session = sessions[id], !session.isAttached,
              let config = configuration.hostSessions, let host = sessionHost(for: session.lane) else {
            launchAttachPending = nil
            return
        }
        guard let listing = hostListings[host] else {
            // A host that is never asked (not a Mac) or did not answer leaves
            // the lane to be attached by hand.
            let asked = listingHosts.map { HostSessions.askedHosts($0).contains { $0.name == host } } ?? false
            if unknownHosts.contains(host) || !asked { launchAttachPending = nil }
            return
        }
        launchAttachPending = nil
        let remote = host == listingHosts?.selfName ? nil : host
        guard let target = HostSessions.target(for: session.lane, backend: session.backend, listing: listing,
                                               config: config, remoteHost: remote),
              let launch = HostSessions.launch(target, lane: session.lane, shell: AgentLaneSession.loginShell,
                                               config: config) else { return }
        attachOnly(id, with: launch, focus: isShowing)
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
            claimOwnership(of: session)
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
        guard let session = sessions[id] else { return }
        if let value = session.customTitle {
            guard value != before else { return }
            session.titleSync.rowRenamed(to: value)
            flushPendingRename(id, showNotice: true)
        } else {
            session.titleSync.rowReset(sessionTitle: session.sessionTitle)
            saveTitleSync(id)
        }
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

    /// Type a queued rename into the lane's agent if it can take it now. A
    /// lane that is busy, asking permission, has text typed, or whose agent
    /// is not in front keeps the rename queued for the next sweep; one that
    /// cannot rename at all drops it.
    func flushPendingRename(_ id: AgentLane.ID, showNotice: Bool = false) {
        guard let session = sessions[id], let name = session.titleSync.pending else { return }
        let command = session.backend.renameCommand.flatMap { LaneRename.command(format: $0, name: name) }
        let outcome = AgentRenameOutcome.decide(command: command, enabled: renamesAgentSession,
                                                attached: session.isAttached, agentInForeground: session.acceptsText,
                                                state: session.record?.state, input: session.readInputLine)
        switch outcome {
        case .sent:
            if let command { session.typeCommand(command) }
            session.titleSync.typed()
            session.showRenameNotice(nil)
        case .notSupported, .disabled:
            session.titleSync.rowReset(sessionTitle: session.sessionTitle)
            saveTitleSync(id)
        case .notAttached, .agentNotInForeground, .busy, .askingPermission, .inputNotEmpty, .inputUnknown:
            if showNotice { session.showRenameNotice(outcome.notice) }
        }
    }

    /// Retry every queued rename.
    func flushPendingRenames() {
        for (id, session) in sessions where session.titleSync.hasPending { flushPendingRename(id) }
    }

    /// Take a session title read from the agent: the row follows it when it
    /// is a change the row has not already made or sent.
    func adopt(sessionTitle title: String?, for id: AgentLane.ID) {
        guard let session = sessions[id] else { return }
        session.update(sessionTitle: title)
        guard renamesAgentSession else { return }
        let before = session.titleSync
        if let name = session.titleSync.observe(title: title, rowName: session.customTitle) { setName(id, to: name) }
        if session.titleSync != before { saveTitleSync(id) }
    }

    private func saveTitleSync(_ id: AgentLane.ID) {
        var all = defaults.dictionary(forKey: keys.titleSync) as? [String: String] ?? [:]
        all[id] = sessions[id]?.titleSync.acknowledged
        defaults.set(all, forKey: keys.titleSync)
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

    /// The app's own default for a new session, when the person has chosen
    /// neither a New Sessions agent nor a Runs backend in Settings; nil, or
    /// an id with no backend, keeps the first installed one. Set it to the
    /// backend the app starts new sessions on, so the New Session menus
    /// name the same agent.
    public var defaultNewSessionBackendID: (() -> String?)?

    /// The id of the backend built from the person's own command in Settings.
    public static let customBackendID = "agentsmate.custom"

    /// What a new lane runs: ``newSessionPlan(preferring:switchingOnUsage:usages:)``
    /// for what Settings says, so the person's New Sessions agent and the
    /// usage switch apply.
    public var newLaneBackendID: String { newSessionPlan().backendID }

    /// What Settings › Runs says a new lane runs, else the first installed
    /// backend, before the New Sessions agent or usage have a say.
    public var configuredNewLaneBackendID: String {
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
        if let id = defaultNewSessionBackendID?(), backends[id] != nil { return id }
        return installedBackends.first?.id ?? CommandLaneBackend.shell.id
    }

    /// Open a lane the person can close, in `directory`, running what
    /// Settings says a new lane runs. `backendID` is the app's default for
    /// a new session: the person's New Sessions agent and the usage switch
    /// win over it (``newSessionPlan(preferring:switchingOnUsage:usages:)``)
    /// unless `followsAgentChoice` is false.
    @discardableResult
    public func openNewLane(in directory: URL? = nil, backendID: String? = nil, focus: Bool = true,
                            open shouldOpen: Bool = true, section: String? = nil,
                            followsAgentChoice: Bool = true) -> AgentLaneSession? {
        let directory = directory.map(Self.canonicalFolder)
        let id = followsAgentChoice ? newSessionPlan(preferring: backendID, in: directory).backendID
            : backendID ?? configuredNewLaneBackendID
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
        defer {
            restoreSettled = true
            sharedLanes?.start()
        }
        let reopen = defaults.object(forKey: keys.reopenLast) as? Bool ?? true
        if reopen, configuration.workspaceFile != nil, restoreAtLaunch() { return }
        if defaults.bool(forKey: keys.openAtLaunch), !lanes.contains(where: \.isClosable) {
            openNewLane(in: newLaneDirectory, focus: false, open: false)
        }
    }

    /// Every backend a lane can run on, by name. The backend of an accessory lane is left out: it runs that lane and
    /// nothing else, so no menu offers it for a new, duplicated or switched lane.
    public var availableBackends: [any LaneBackend] {
        let hidden = Set(accessoryLanes.map(\.backendID)).subtracting(listedLanes.map(\.backendID))
        return backends.values.filter { !hidden.contains($0.id) }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// A new lane like this one, in the same folder and section, just after
    /// it, named "<name> 2" (or the next free number), running `backendID`
    /// or else what a new lane in that folder starts on.
    ///
    /// The copy starts a session of its own, the way a brand-new lane does,
    /// and never attaches one that is already running.
    @discardableResult
    public func duplicate(_ id: AgentLane.ID, backendID: String? = nil, focus: Bool = true) -> AgentLaneSession? {
        guard let source = lanes.first(where: { $0.id == id }), let session = sessions[id] else { return nil }
        guard canDuplicate(id, backendID: backendID) else { return nil }
        var lane = source
        lane.id = UUID().uuidString
        lane.isClosable = true
        if source.directory == nil { lane.directory = URL(fileURLWithPath: session.currentDirectory) }
        lane.backendID = backendID ?? duplicateBackendID(for: source, in: lane.directory)
        // A Claude background session is started by this Mac's own `claude`,
        // so a copy that will run one is a lane on this Mac, whatever name
        // the registry gave this Mac in the source row.
        if backends[lane.backendID] is ClaudeBackgroundLaneBackend { lane.host = nil }
        lane.section = layout.section(of: source)
        lane.statusMatch = nil
        // The copy is a lane of its own, not another view of the same session.
        lane.sessionName = nil
        lane.agentSessionID = nil
        // A persistent lane in the same folder would attach the same session,
        // so the copy asks for a lane of its own: the next free number.
        lane.variant = nil
        lane.variant = freeVariant(for: lane)
        let name = session.title.nextCopyName(taken: copyNamesTaken(in: lane.path))
        // A Claude background copy starts a session of its own, named after
        // itself, and binds only the id that start prints.
        if backends[lane.backendID] is ClaudeBackgroundLaneBackend {
            lane.sessionName = name
            lane.startsNewSession = true
        }
        let added = add(lane, focus: focus, after: id)
        setName(lane.id, to: name)
        if let added { claimOwnership(of: added, created: true) }
        return added
    }

    /// Whether `host` names this Mac: nil, one of its own names, or the name
    /// the hosts registry gives it.
    func isThisMac(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true }
        let names = AgentHosts.thisMacNames.union(liveSelfName.map { [$0] } ?? []).map { $0.lowercased() }
        return names.contains(host.lowercased())
    }

    /// Whether a duplicate of a lane can work. A Claude background session
    /// is started by `claude` on this Mac, so a lane on another host cannot
    /// be copied onto it; the menu leaves that choice off rather than start
    /// something that only prints a refusal.
    public func canDuplicate(_ id: AgentLane.ID, backendID: String? = nil) -> Bool {
        guard let source = lanes.first(where: { $0.id == id }) else { return false }
        let target = backendID ?? duplicateBackendID(for: source, in: source.directory)
        guard backends[target] is ClaudeBackgroundLaneBackend else { return true }
        return isThisMac(source.host)
    }

    /// Names a copy must not take: every row's title and session name, and
    /// the sessions running in `folder` (found by the sweep, or in this
    /// Mac's Claude list).
    func copyNamesTaken(in folder: String) -> Set<String> {
        var taken = Set(sessions.values.map(\.title))
        taken.formUnion(lanes.compactMap(\.sessionName))
        let path = normalizedPath(folder)
        taken.formUnion(discovered.filter { $0.session.directory.map(normalizedPath) == path }.map(\.session.name))
        for backend in backends.values {
            guard let claude = backend as? ClaudeBackgroundLaneBackend,
                  let data = try? Data(contentsOf: claude.agentsListCache) else { continue }
            taken.formUnion(ClaudeAgentsList.parse(data).filter { $0.directory.map(normalizedPath) == path }.compactMap(\.lane))
        }
        return taken
    }

    /// What a "Same Agent" duplicate of `source` runs. A lane on an agent
    /// starts the way a new lane in its folder does (the New Sessions
    /// choice, else the source's own backend); a Claude background lane
    /// takes what a new session in that folder starts on, folder rules and
    /// all. Anything else, such as a shell, keeps its backend.
    func duplicateBackendID(for source: AgentLane, in folder: URL?) -> String {
        if backends[source.backendID] is ClaudeBackgroundLaneBackend {
            let plan = newSessionPlan(in: folder).backendID
            return backends[plan] == nil ? source.backendID : plan
        }
        guard agentKind(ofBackend: source.backendID) != nil else { return source.backendID }
        let plan = newSessionPlan(preferring: source.backendID, in: folder).backendID
        return backends[plan] == nil ? source.backendID : plan
    }

    /// The variant a new lane needs so it is a session of its own: nil when
    /// its backend's sessions end with their terminal or no lane of that
    /// backend uses its folder, else the next free number from 2.
    func freeVariant(for lane: AgentLane) -> String? {
        guard let backend = backends[lane.backendID], backend.keepsRunningWhenDetached else { return nil }
        let path = normalizedPath(lane.path)
        let sharing = lanes.filter { $0.backendID == lane.backendID && normalizedPath($0.path) == path }
        guard !sharing.isEmpty else { return nil }
        let used = Set(sharing.map { $0.variant ?? "1" })
        // A variant whose session still runs with no row would attach it.
        let running = Set(discovered.filter { $0.backendID == lane.backendID }.map(\.session.name))
        func live(_ variant: String) -> Bool {
            var candidate = lane
            candidate.variant = variant
            return backend.sessionName(for: candidate).map(running.contains) ?? false
        }
        var n = 2
        while used.contains(String(n)) || live(String(n)) { n += 1 }
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
        await newLane(in: group, backendID: backendID, focus: focus, folder: nil)
    }

    private func newLane(in group: LaneGroup, backendID: String, focus: Bool, folder chosen: URL?) async -> AgentLaneSession? {
        guard canAddLane(to: group), backends[backendID] != nil else { return nil }
        var picked = chosen
        if picked == nil { picked = await configuration.chooseFolder(startingFolder(for: group)) }
        guard let folder = picked else { return nil }
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
        let added = add(lane, focus: focus)
        if let added { claimOwnership(of: added, created: true) }
        return added
    }

    /// Ask for a folder, then open a lane in `group` there on the agent a
    /// new session starts on for that folder
    /// (``newSessionPlan(preferring:in:switchingOnUsage:usages:)``).
    @discardableResult
    public func newSessionLane(in group: LaneGroup, focus: Bool = true) async -> AgentLaneSession? {
        guard canAddLane(to: group) else { return nil }
        guard let chosen = await configuration.chooseFolder(startingFolder(for: group)) else { return nil }
        // One resolved folder for the check, the plan and the lane itself.
        let folder = Self.canonicalFolder(chosen)
        return await newLane(in: group, backendID: newSessionPlan(in: folder).backendID, focus: focus,
                             folder: folder)
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
        session.onAttentionChange = { [weak self] _ in self?.updateBadge() }
        session.onUserInteraction = { [weak self] session in self?.claimOwnership(of: session) }
        session.customTitle = layout.names[id]
        session.titleSync = LaneTitleSync(acknowledged: (defaults.dictionary(forKey: keys.titleSync) as? [String: String])?[id])
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
        if let snapshot = liveSnapshot {
            session.liveHint = LiveSnapshotSeed.hint(for: lane, backend: backend, host: liveHost(for: lane), in: snapshot)
        }
        sessions[lane.id] = session
        session.isSelected = id == selectedID || id == splitID
        session.isShown = isShowing && !isHomeShown && session.isSelected
    }

    /// Show a lane, attaching it the first time or after it ended. Opening a
    /// lane that is already attached only shows it.
    public func open(_ id: AgentLane.ID, focus: Bool = true) {
        guard let session = sessions[id] else { return }
        launchAttachPending = nil
        showingHome = false
        recordVisit(id)
        if id == splitID { splitID = selectedID == id ? nil : selectedID }
        selectedID = id
        let starting = !session.isAttached
        if !suppressOwnerClaim { claimOwnership(of: session) }
        start(session)
        if focus { session.wantsFocus = true }
        updateShown()
        if starting, !detachedIDs.contains(id) { claimAfterAttach() }
    }

    /// Show Home in place of the terminal (``AgentHomeView``), keeping the
    /// selection so opening it again goes back to the same lane.
    public func showHome() {
        guard configuration.showsHome else { return }
        launchAttachPending = nil
        firstShowPending = false
        showingHome = true
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
    public var groups: [LaneGroup] { listSnapshot.groups }

    // MARK: Sidebar width

    /// The least width the lane list takes, before its controls are measured.
    public static let sidebarBaseMinimumWidth: CGFloat = 360

    /// How wide the lane list must be for its filter bar: the status chips
    /// (sized for two-digit counts) and the controls beside them, the gap
    /// between, the bar's padding and some room, and never under
    /// ``sidebarBaseMinimumWidth``.
    static func sidebarMinimumWidth(chips: CGFloat, controls: CGFloat) -> CGFloat {
        let padding: CGFloat = 20, gap: CGFloat = 4, room: CGFloat = 16
        return max(sidebarBaseMinimumWidth, (chips + controls + gap + padding + room).rounded(.up))
    }

    /// The width the lane list needs, measured from its filter bar. A split
    /// view or dock showing the list keeps it at least this wide.
    /// Where the sidebar's header (the search field and the count row) ends,
    /// as a y in the window, while the sidebar is on screen.
    /// All Agents' header is made as tall as it takes to end at the same
    /// line, so the two dividers meet across the window.
    @Published var sidebarHeaderBottom: CGFloat?
    @Published public internal(set) var sidebarMinimumWidth: CGFloat = AgentLaneStore.sidebarBaseMinimumWidth

    // MARK: List snapshot

    /// The list as the sidebar draws it. Worked out once for each change of
    /// what it depends on (lanes, layout, the app's order, found sessions and,
    /// for the recency sorts, each lane's last activity), so drawing the list
    /// reads it rather than grouping and sorting again for every header and row.
    public struct ListSnapshot: Equatable, Sendable {
        /// The lanes in the app's default order (``defaultRepositoryOrder``).
        public let orderedLanes: [AgentLane]
        public let groups: [LaneGroup]
        /// The rows ⌘1–⌘9 go to; see ``AgentLaneStore/numberedLanes``.
        public let numberedLanes: [AgentLane]
        /// The ⌘ number of each of ``numberedLanes``.
        public let shortcutNumbers: [AgentLane.ID: Int]
        /// Every section a lane can be moved to.
        public let sectionNames: [String]
        /// The ``LaneGroup/collapseKey`` of every group.
        public let collapseKeys: Set<String>
        /// How many groups are neither Pinned nor Detached.
        public let regularGroupCount: Int
    }

    private struct ListSnapshotKey: Equatable {
        var lanes: [AgentLane]
        var layout: LaneLayout
        var repositoryOrder: [String]
        var detached: Set<AgentLane.ID>
        var owners: [AgentLane.ID: AgentLane.ID]
        var placesDetached: Bool
        var activity: [Date?]
    }

    private var cachedListSnapshot: (key: ListSnapshotKey, value: ListSnapshot)?
    /// How many times the snapshot has been worked out, for tests.
    private(set) var listSnapshotBuilds = 0

    /// The list as it stands; see ``ListSnapshot``.
    public var listSnapshot: ListSnapshot {
        let key = ListSnapshotKey(lanes: lanes, layout: layout, repositoryOrder: defaultRepositoryOrder,
                                  detached: detachedIDs, owners: detachedOwners,
                                  placesDetached: configuration.placesDetachedSessions,
                                  activity: layout.sort == .manual ? [] : lanes.map { sessions[$0.id]?.lastActivity })
        if let cached = cachedListSnapshot, cached.key == key { return cached.value }
        let value = buildListSnapshot()
        cachedListSnapshot = (key, value)
        listSnapshotBuilds += 1
        return value
    }

    /// The snapshot worked out from scratch, ignoring the cache.
    func buildListSnapshot() -> ListSnapshot {
        let ordered = computeOrderedLanes()
        let groups = computeGroups(ordered)
        let detached = detachedIDs
        // A found session listed under a pinned row is not pinned itself.
        let numbered = Array((groups.first(where: \.isPinned)?.lanes ?? []).filter { !detached.contains($0.id) }.prefix(9))
        return ListSnapshot(orderedLanes: ordered, groups: groups, numberedLanes: numbered,
                            shortcutNumbers: Dictionary(numbered.enumerated().map { ($1.id, $0 + 1) },
                                                        uniquingKeysWith: { first, _ in first }),
                            sectionNames: layout.orderedSections(for: ordered),
                            collapseKeys: Set(groups.map(\.collapseKey)),
                            regularGroupCount: groups.filter { !$0.isPinned && !$0.isDetached }.count)
    }

    private func computeGroups(_ orderedLanes: [AgentLane]) -> [LaneGroup] {
        let detached = detachedIDs
        var groups = layout.groups(for: orderedLanes.filter { !detached.contains($0.id) }) { [sessions] lane in
            sessions[lane.id]?.lastActivity
        }
        guard !detached.isEmpty else { return groups }
        // Each found session goes just under the row whose folder holds it,
        // after any found before it; the rest make the Detached group.
        var loose: [AgentLane] = []
        for lane in lanes where detached.contains(lane.id) {
            guard configuration.placesDetachedSessions, let owner = detachedOwners[lane.id],
                  let g = groups.firstIndex(where: { $0.lanes.contains { $0.id == owner } }),
                  let index = groups[g].lanes.firstIndex(where: { $0.id == owner }) else {
                loose.append(lane)
                continue
            }
            var at = index + 1
            while at < groups[g].lanes.count, detached.contains(groups[g].lanes[at].id) { at += 1 }
            groups[g].lanes.insert(lane, at: at)
        }
        if !loose.isEmpty {
            groups.append(LaneGroup(section: LaneLayout.detachedSection, lanes: loose, isDetached: true))
        }
        return groups
    }

    /// The lanes in the order the list shows them; cycling follows it.
    public var displayOrder: [AgentLane] {
        groups.flatMap(\.lanes)
    }

    /// The rows ⌘1–⌘9 go to: the pinned ones, in the order the list shows
    /// them. A row that is not pinned has no number, so pinning is how a
    /// person chooses which rows the keys reach.
    public var numberedLanes: [AgentLane] { listSnapshot.numberedLanes }

    /// Open the pinned row ⌘ and `index + 1` goes to.
    public func open(index: Int) {
        let numbered = numberedLanes
        guard numbered.indices.contains(index) else { return }
        open(numbered[index].id)
    }

    // MARK: Layout

    public func addSection(_ name: String) { layout.addSection(name) }
    public func renameSection(_ old: String, to new: String) { layout.renameSection(old, to: new, lanes: orderedLanes) }
    public func removeSection(_ name: String) { layout.removeSection(name, lanes: lanes) }
    public func moveSection(_ name: String, by offset: Int) { layout.moveSection(name, by: offset, lanes: orderedLanes) }
    /// Put a section before another, or last when `target` is nil.
    public func moveSection(_ name: String, before target: String?) {
        layout.moveSection(name, before: target, lanes: orderedLanes)
    }
    public func move(_ id: AgentLane.ID, to section: String?) { layout.move(id, to: section) }
    public func setPinned(_ id: AgentLane.ID, _ pinned: Bool) { layout.setPinned(id, pinned) }
    public func moveLane(_ id: AgentLane.ID, before target: AgentLane.ID?) {
        layout.moveLane(id, before: target, lanes: orderedLanes)
    }
    public func setSort(_ sort: LaneLayout.Sort) { layout.sort = sort }

    public func toggleCollapsed(_ section: String) {
        if layout.collapsed.contains(section) { layout.collapsed.remove(section) } else { layout.collapsed.insert(section) }
    }

    public func setAllCollapsed(_ collapsed: Bool) {
        layout.collapsed = collapsed
            ? Set(layout.orderedSections(for: orderedLanes) + [LaneLayout.pinnedSection, LaneLayout.detachedSection,
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
        let snapshot = listSnapshot
        return snapshot.groups.count > 1
            && snapshot.collapseKeys.subtracting([group.collapseKey]) != layout.collapsed
    }

    // MARK: Repository order

    /// The app's order for its lanes, as folder paths; see
    /// ``Configuration/defaultRepositoryOrder``. Set it again when the app's
    /// list changes.
    @Published public var defaultRepositoryOrder: [String] = []

    /// The lanes in the app's default order (``defaultRepositoryOrder``),
    /// the rest after them as given. What the layout orders.
    var orderedLanes: [AgentLane] { listSnapshot.orderedLanes }

    private func computeOrderedLanes() -> [AgentLane] {
        let lanes = listedLanes
        guard !defaultRepositoryOrder.isEmpty else { return lanes }
        var rank: [String: Int] = [:]
        for (index, path) in defaultRepositoryOrder.enumerated() {
            let key = repositoryKey(path)
            if rank[key] == nil { rank[key] = index }
        }
        // Each lane's rank is looked up once, before the sort, so the
        // comparator never normalizes a path.
        let ranked = lanes.enumerated().map { (offset: $0.offset, rank: rank[repositoryKey($0.element.path)] ?? Int.max,
                                               lane: $0.element) }
        return ranked.sorted { a, b in a.rank != b.rank ? a.rank < b.rank : a.offset < b.offset }.map(\.lane)
    }

    /// ``LaneLayout/repositoryKey(_:)``, kept per path because resolving
    /// one reads the disk.
    func repositoryKey(_ path: String) -> String { normalizedPath(path) }

    /// The rows the person can order, pinned ones in their place, in list
    /// order: sections in order, then lanes within each.
    private var orderableRows: [AgentLane] {
        var unpinned = layout
        unpinned.pinned = []
        unpinned.sort = .manual
        return unpinned.groups(for: orderedLanes.filter { !detachedIDs.contains($0.id) }) { _ in nil }.flatMap(\.lanes)
    }

    /// Every folder the rows work in (``LaneLayout/repositoryKey(_:)``), in
    /// list order: by section, then within each section.
    public var repositoryOrder: [String] {
        var seen = Set<String>()
        return orderableRows.map { repositoryKey($0.path) }.filter { seen.insert($0).inserted }
    }

    /// The section each folder's row is in, by ``LaneLayout/repositoryKey(_:)``.
    public func section(ofRepository path: String) -> String? {
        let key = repositoryKey(path)
        return orderableRows.first { repositoryKey($0.path) == key }.flatMap { layout.section(of: $0) }
    }

    /// Whether the person has an order of their own for sections or rows,
    /// which Reset to Default Order clears.
    public var hasCustomRepositoryOrder: Bool {
        !layout.order.isEmpty || layout.sections.contains { name in lanes.contains { layout.section(of: $0) == name } }
    }

    /// `paths` in the list's order, for any list of repositories an app
    /// shows; paths it does not know keep their order after the rest.
    public func orderedRepositories(_ paths: [String]) -> [String] {
        var rank: [String: Int] = [:]
        for (index, key) in repositoryOrder.enumerated() { rank[key] = index }
        for (index, path) in defaultRepositoryOrder.enumerated() where rank[repositoryKey(path)] == nil {
            rank[repositoryKey(path)] = rank.count + index
        }
        return paths.enumerated().sorted { a, b in
            let ra = rank[repositoryKey(a.element)] ?? Int.max
            let rb = rank[repositoryKey(b.element)] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Put the rows of `paths` in that order, each where one of them was,
    /// as dragging a settings list does; every other row keeps its place.
    public func setRepositoryOrder(_ paths: [String]) {
        let current = layout.orderedIDs(orderedLanes)
        var byKey: [String: [AgentLane.ID]] = [:]
        for lane in orderedLanes where !detachedIDs.contains(lane.id) {
            byKey[repositoryKey(lane.path), default: []].append(lane.id)
        }
        let wanted = paths.flatMap { byKey[repositoryKey($0)] ?? [] }
        let moving = Set(wanted)
        guard !moving.isEmpty else { return }
        var queue = wanted[...]
        layout.order = current.map { id in moving.contains(id) ? queue.popFirst() ?? id : id }
        if layout.sort != .manual { layout.sort = .manual }
    }

    /// Put the sections in this order; sections it leaves out follow.
    public func setSectionOrder(_ names: [String]) {
        var seen = Set<String>()
        layout.sections = (names + layout.orderedSections(for: orderedLanes)).filter { seen.insert($0).inserted }
    }

    /// Go back to the app's order for sections and rows. Sections the
    /// person made that hold no lane stay.
    public func resetRepositoryOrder() {
        layout.order = []
        layout.sections = layout.sections.filter { name in !lanes.contains { layout.section(of: $0) == name } }
    }

    /// Every section a lane can be moved to.
    public var sectionNames: [String] { listSnapshot.sectionNames }

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

    /// Hide a lane the person opened and end its terminal here. Never ends
    /// the agent's session: a session that outlives its terminal (tmux, a
    /// Claude background session) keeps running and is listed as Detached;
    /// ``stop(_:)`` is what ends it.
    public func close(_ id: AgentLane.ID) {
        guard let index = lanes.firstIndex(where: { $0.id == id }), lanes[index].isClosable else { return }
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
        if !detachedIDs.contains(id) { sharedLanes?.closed(id) }
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

    /// How far above the app's ``Configuration/baseFontSize`` a terminal
    /// starts: one ⌘+ step, so the default reads larger in every app. Zoom
    /// adds to it and ⌘0 returns to it.
    public static let defaultFontStep: CGFloat = 1

    /// The size terminals start at and ⌘0 returns to.
    public var defaultFontSize: CGFloat { configuration.baseFontSize + Self.defaultFontStep }

    public var fontSize: CGFloat {
        min(max(defaultFontSize + fontOffset, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    public var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    public func adjustFont(by points: CGFloat) {
        let target = min(max(fontSize + points, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        setFontOffset(target - defaultFontSize)
    }

    /// Back to the default size.
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
        case .reopen(let kind):
            // ⇧⌘C and ⇧⌘X switch agents in every app, whether or not it lists
            // Reopen As choices; the rest of the kinds are the app's choices.
            if kind == .claudeRemote || kind == .codexRemote, let agent = kind.agentKind {
                return switchAgent(id, to: agent)
            }
            return reopen(id, kind: kind)
        }
        return true
    }

    /// How a lane's status is found. A lane that owns a session on this
    /// Mac by the bindings shows that session and no other: the record
    /// whose short id is exactly the bound one, by its full session id (so
    /// hook events for it count too), and nothing while none is listed.
    /// Otherwise as the lane or its backend says.
    func statusMatch(for session: AgentLaneSession, records: [LaneStatus]? = nil) -> LaneStatusMatch {
        if let owned = ownedSession(for: session.lane), owned.host == nil {
            let records = records ?? statusFeed?.records ?? []
            guard let id = records.first(where: { $0.agentID == owned.agentID })?.sessionID, !id.isEmpty else { return .none }
            return .session(id)
        }
        return session.lane.statusMatch ?? session.backend.statusMatch(for: session.lane)
    }

    private func apply(_ records: [LaneStatus]) {
        recordBackgroundSessionIDs(records)
        var held: [AgentLane.ID: [String]] = [:]
        var owned: [AgentLane.ID: DetachedSessions.OwnedSession] = [:]
        let listed = records.filter(\.isPolled)
        for session in sessions.values {
            let match = statusMatch(for: session, records: records)
            let record = match.find(in: records)
            session.update(record: record, polled: record?.isPolled == true ? record : match.find(in: listed))
            guard !detachedIDs.contains(session.id) else { continue }
            if let own = ownedSession(for: session.lane) {
                owned[session.id] = own
                // A bound id is matched by host and exactly, below; it never
                // joins the ids held on every host.
                if own.host == nil { continue }
            }
            let ids = DetachedSessions.heldSessionIDs(match: match, record: record)
            if !ids.isEmpty { held[session.id] = ids }
        }
        objectWillChange.send()
        defer { noticeStatusSessions(records) }
        // A row that has just picked up a session (its wrapper wrote the id,
        // or a hook reported it) takes it out of Detached now, not at the
        // next sweep. Nothing runs here: the last sweep is matched again.
        if held != heldSessionIDs || owned != ownedSessionIDs {
            heldSessionIDs = held
            ownedSessionIDs = owned
            if !discovered.isEmpty { reconcileDetached() }
        }
    }

    /// Give each attached Claude background row on this Mac the short id of
    /// its session once the list shows exactly one with its name in its
    /// folder, so it is attached and restored by that id from then on. A
    /// name that several sessions share, or an id another row holds, is
    /// left alone.
    func recordBackgroundSessionIDs(_ records: [LaneStatus]) {
        defer { syncSessionHolders() }
        let listed = records.filter { $0.event == ClaudeAgentsList.event }
        // A row made from a session holds that session's id and no other.
        for index in lanes.indices {
            guard let own = DetachedSessions.ownAgentID(ofLaneID: lanes[index].id),
                  lanes[index].agentSessionID != own else { continue }
            lanes[index].agentSessionID = own
            lanes[index].agentConversationID = nil
            sessions[lanes[index].id]?.update(lane: lanes[index])
        }
        var holding = Set(lanes.compactMap(\.agentSessionID))
        // A row that holds a short id learns the full session id behind it
        // from that id's own record, never from a name or folder.
        for index in lanes.indices {
            guard let id = lanes[index].agentSessionID, lanes[index].host == nil,
                  backends[lanes[index].backendID] is ClaudeBackgroundLaneBackend,
                  let full = listed.first(where: { $0.agentID == id })?.sessionID,
                  ClaudeBackgroundLaneBackend.isValidConversationID(full),
                  lanes[index].agentConversationID != full else { continue }
            lanes[index].agentConversationID = full
            sessions[lanes[index].id]?.update(lane: lanes[index])
        }
        for index in lanes.indices {
            let lane = lanes[index]
            guard lane.agentSessionID == nil, lane.host == nil, !detachedIDs.contains(lane.id),
                  DetachedSessions.ownAgentID(ofLaneID: lane.id) == nil,
                  let backend = backends[lane.backendID] as? ClaudeBackgroundLaneBackend,
                  let session = sessions[lane.id] else { continue }
            // The id its own start printed binds first, and is the only one
            // a row that must start a new session ever takes.
            if let id = backend.startedID(for: lane) {
                lanes[index].agentSessionID = id
                lanes[index].startsNewSession = false
                holding.insert(id)
                session.update(lane: lanes[index])
                try? FileManager.default.removeItem(at: backend.startedIDFile(for: lane))
                continue
            }
            guard !lane.startsNewSession, session.isAttached, !listed.isEmpty,
                  let name = backend.sessionName(for: lane),
                  case .one(let id) = ClaudeBackgroundLaneBackend.resolve(name: name, in: lane.path, records: listed),
                  !holding.contains(id) else { continue }
            lanes[index].agentSessionID = id
            holding.insert(id)
            session.update(lane: lanes[index])
        }
    }

    /// Whether a Claude background row is a session this Mac can resume in
    /// its own pane.
    public func canResumeBackground(_ id: AgentLane.ID) -> Bool {
        guard let session = sessions[id], session.lane.host == nil, session.lane.agentSessionID != nil else { return false }
        return session.backend is ClaudeBackgroundLaneBackend
    }

    /// Whether the row's background session is running, per the daemon's
    /// list. Unknown counts as running, so nothing is resumed over it.
    public func isBackgroundLive(_ id: AgentLane.ID) -> Bool {
        guard let session = sessions[id], let backend = session.backend as? ClaudeBackgroundLaneBackend,
              let short = session.lane.agentSessionID else { return false }
        return backend.liveness(of: short) != .stopped
    }

    /// Run `claude --resume <full session id>` in the row's own pane. With
    /// `stoppingBackground`, `claude stop <id>` runs first and finishes
    /// before it. Never starts a new session.
    public func resumeBackground(_ id: AgentLane.ID, stoppingBackground: Bool) {
        guard canResumeBackground(id), let session = sessions[id],
              let backend = session.backend as? ClaudeBackgroundLaneBackend else { return }
        if !stoppingBackground, isBackgroundLive(id) { return }
        let launch = backend.resumeLaunch(for: session.lane, shell: AgentLaneSession.loginShell,
                                          stoppingBackground: stoppingBackground)
        session.detach()
        session.resumeOnStart = false
        session.attachOnlyLaunch = launch
        open(id)
    }

    /// Tell each Claude background backend which row holds which id.
    func syncSessionHolders() {
        var byID: [String: String] = [:]
        for lane in lanes { if let id = lane.agentSessionID { byID[id] = lane.id } }
        for backend in backends.values { (backend as? ClaudeBackgroundLaneBackend)?.holders.set(byID) }
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

    func apply(presence: [LanePresence]) {
        for session in sessions.values {
            let match = statusMatch(for: session)
            var found = presence.locate(for: session.lane, match: match)
            // A pane with no Claude or Codex process is not a running agent.
            if found?.presence.hasAgent == false { found = nil }
            // A background session's row is its own session, never a tmux
            // session that merely works in the same folder.
            if session.backend is ClaudeBackgroundLaneBackend, found?.byName != true { found = nil }
            session.update(orphan: configuration.highlightsOrphans && found?.presence.attachedClients == 0 && !session.isAttached)
            session.update(present: found != nil, byName: found?.byName ?? false, name: found?.presence.name)
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
        flushPendingRenames()
        guard !readingTranscripts else { return }
        var wanted: [AgentLane.ID: LaneTranscriptCache.Source] = [:]
        var records: [AgentLane.ID: LaneStatus] = [:]
        for (id, session) in sessions {
            if let source = LaneTranscriptCache.Source(session.record) { wanted[id] = source; records[id] = session.record }
        }
        guard !wanted.isEmpty else { return }
        readingTranscripts = true
        let cache = transcripts
        Task.detached(priority: .background) {
            var cache = cache
            let changed = cache.read(Set(wanted.values))
            var titles: [AgentLane.ID: String?] = [:]
            for (id, source) in wanted { titles[id] = cache.title(source: source, record: records[id]) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.readingTranscripts = false
                self.transcripts = cache
                var selectedChanged = false
                for (id, title) in titles { self.adopt(sessionTitle: title, for: id) }
                self.flushPendingRenames()
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
            session.isShown = isShowing && !isHomeShown && session.isSelected
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
    public var filterUnread: String { prefix + "filterUnread" }
    public var fontOffset: String { prefix + "fontOffset" }
    public var layout: String { prefix + "layout" }
    var layoutChanged: String { prefix + "layoutChanged" }
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
    /// The agent session title each row has already settled with, by lane.
    public var titleSync: String { prefix + "titleSync" }
    /// The person's sidebar shape, over the app's defaults
    /// (``AgentSidebarSettingsSection``).
    public var showsSectionHeadings: String { prefix + "showsSectionHeadings" }
    public var showsLaneIcons: String { prefix + "showsLaneIcons" }
    public var showsPullRequestPills: String { prefix + "showsPullRequestPills" }
    public var parallelSessions: String { prefix + "parallelSessions" }
    /// The agent new sessions start on, as a ``LaneReopenChoice/Kind`` raw
    /// value (`claudeRemote`, `codexRemote`, `claudeDirect`, `codexDirect`);
    /// absent follows the app's default.
    public var newSessionAgent: String { prefix + "newSessionAgent" }
    /// Whether a new session starts on the other agent when the chosen one
    /// is near its usage limit. On when absent.
    public var switchesAgentNearLimit: String { prefix + "switchesAgentNearLimit" }
    /// The usage, in percent, at which that switch happens. 90 when absent.
    public var agentSwitchThreshold: String { prefix + "agentSwitchThreshold" }
}
