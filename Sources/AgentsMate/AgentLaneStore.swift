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
        /// closing a workspace in a terminal multiplexer does.
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

        public init(termProgram: String, environment: [String: String] = [:],
                    baseFontSize: CGFloat = NSFont.systemFontSize,
                    scrollback: Int = 20_000, shortcuts: TerminalShortcut.Set = .fixedLanes,
                    defaultsPrefix: String = "agentsmate.", highlightsOrphans: Bool = false,
                    closeStopsLane: Bool = true,
                    sessionFileDirectory: URL? = FileManager.default.temporaryDirectory
                        .appendingPathComponent("agentsmate-sessions", isDirectory: true),
                    cycleSkipsUnstarted: Bool = false, workspaceFile: URL? = nil,
                    showsRowMetadata: Bool = false, notifies: Bool = false) {
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

    @Published public private(set) var lanes: [AgentLane] = []
    @Published public private(set) var sessions: [AgentLane.ID: AgentLaneSession] = [:]
    @Published public var selectedID: AgentLane.ID? {
        didSet {
            defaults.set(selectedID, forKey: keys.selectedLane)
            updateShown()
        }
    }
    /// The lane shown beside the selected one, when split.
    @Published public var splitID: AgentLane.ID? { didSet { updateShown() } }
    /// Whether the lanes are on screen; set by the view that shows them.
    public var isShowing = false { didSet { updateShown() } }

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
    private func start(_ session: AgentLaneSession) {
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

    /// Sections, pins, order and sort, as the person left them.
    @Published public var layout = LaneLayout() {
        didSet {
            guard layout != oldValue, let data = try? JSONEncoder().encode(layout) else { return }
            defaults.set(data, forKey: keys.layout)
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
        self.fontOffset = CGFloat(defaults.double(forKey: keys.fontOffset))
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
        if configuration.showsRowMetadata { startRowMetadata() }
        if configuration.notifies { notifier = LaneNotifier(store: self) }
    }

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
    /// name, folder, branch or section; a match at the start of the name
    /// ranks first, then recently active lanes.
    public func paletteResults(_ query: String) -> [AgentLane] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let ordered = displayOrder
        guard !words.isEmpty else { return ordered }
        func haystack(_ lane: AgentLane) -> String {
            let session = sessions[lane.id]
            return [session?.title ?? lane.title, lane.path, session?.rowMetadata.branch ?? "", layout.section(of: lane) ?? ""]
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

    private var notifier: LaneNotifier?

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

    private func updateBadge() {
        guard configuration.notifies, LaneNotifier.isAvailable else { return }
        let count = unreadLanes.count
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: Row metadata

    private var metadataTimer: Timer?
    private var pullRequestCache: [String: (date: Date, value: LaneRowMetadata.PullRequest?)] = [:]
    private var readingMetadata = false
    private let gh = LaneRowMetadataReader.locateGH()

    private func startRowMetadata() {
        refreshRowMetadata()
        metadataTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRowMetadata() }
        }
    }

    /// Read every lane's branch and ports, and the pull request for each
    /// branch at most every five minutes, off the main thread.
    public func refreshRowMetadata() {
        guard !readingMetadata else { return }
        readingMetadata = true
        let jobs = lanes.compactMap { lane -> (String, String, pid_t?)? in
            guard let session = sessions[lane.id] else { return nil }
            return (lane.id, session.isStarted ? session.currentDirectory : lane.path, session.shellPID)
        }
        let cache = pullRequestCache, gh = gh
        Task.detached(priority: .utility) {
            var results: [String: LaneRowMetadata] = [:]
            var fresh: [String: (date: Date, value: LaneRowMetadata.PullRequest?)] = [:]
            for (id, directory, pid) in jobs {
                var meta = LaneRowMetadata()
                meta.branch = LaneRowMetadataReader.branch(in: directory)
                if let pid { meta.ports = LaneRowMetadataReader.listeningPorts(pids: LaneRowMetadataReader.processTree(pid)) }
                if let branch = meta.branch {
                    let key = directory + "#" + branch
                    if let hit = cache[key] ?? fresh[key], Date().timeIntervalSince(hit.date) < 300 {
                        meta.pullRequest = hit.value
                    } else {
                        let value = LaneRowMetadataReader.pullRequest(branch: branch, in: directory, gh: gh)
                        fresh[key] = (Date(), value)
                        meta.pullRequest = value
                    }
                }
                results[id] = meta
            }
            let found = results, cached = fresh
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, meta) in found where self.sessions[id]?.rowMetadata != meta { self.sessions[id]?.rowMetadata = meta }
                self.pullRequestCache.merge(cached) { _, new in new }
                self.readingMetadata = false
            }
        }
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
    }

    public func backend(id: String) -> (any LaneBackend)? { backends[id] }

    public var selected: AgentLaneSession? { selectedID.flatMap { sessions[$0] } }
    public var split: AgentLaneSession? { splitID.flatMap { sessions[$0] } }
    public func session(for lane: AgentLane) -> AgentLaneSession? { sessions[lane.id] }

    /// Replace the app's fixed lanes. Lanes the person opened stay after
    /// them; a fixed lane that disappears is detached; terminals are kept.
    public func sync(lanes fixed: [AgentLane]) {
        let opened = lanes.filter { $0.isClosable && !fixed.map(\.id).contains($0.id) }
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

    private func writeWorkspaces(_ change: (inout LaneWorkspaceFile) -> Void) {
        guard let url = configuration.workspaceFile else { return }
        reloadWorkspaces()
        guard workspaceError == nil else { return }
        var file = workspaces
        change(&file)
        do {
            try file.save(url)
            workspaces = file
        } catch {
            workspaceError = "The workspaces file could not be saved: \(error.localizedDescription)"
        }
    }

    /// The lanes the person opened, with the sections, as a workspace.
    public func snapshot(named name: String, onlyAttached: Bool = false) -> LaneWorkspace {
        let opened = displayOrder.filter { $0.isClosable && (!onlyAttached || sessions[$0.id]?.isAttached == true) }
        let lanes = opened.map { lane in
            LaneWorkspace.Lane(title: layout.names[lane.id],
                               directory: sessions[lane.id]?.currentDirectory ?? lane.directory?.path,
                               backendID: lane.backendID,
                               section: layout.section(of: lane),
                               pinned: layout.pinned.contains(lane.id) ? true : nil)
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
        for saved in workspace.lanes {
            let path = saved.directory.map { ($0 as NSString).expandingTildeInPath }
            let already = lanes.contains { lane in
                lane.backendID == saved.backendID && path.map { LaneStatusMatch.normalizedPath($0) == LaneStatusMatch.normalizedPath(lane.path) } ?? false
            }
            if already { continue }
            let lane = AgentLane(id: UUID().uuidString, title: (path as NSString?)?.lastPathComponent ?? "Lane",
                                 directory: path.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                 backendID: saved.backendID, isClosable: true, section: saved.section)
            add(lane, focus: false, open: false)
            if resume { sessions[lane.id]?.resumeOnStart = true }
            if let title = saved.title { rename(lane.id, to: title) }
            if saved.pinned == true { layout.setPinned(lane.id, true) }
            if first == nil { first = lane.id }
        }
        if let first, selected?.lane.isClosable != true { selectedID = first }
    }

    /// Record the lanes attached now, to reopen at the next launch. Call when
    /// the app quits.
    public func saveRestore() {
        let workspace = snapshot(named: "Last Session", onlyAttached: true)
        writeWorkspaces { $0.restore = workspace.lanes.isEmpty ? nil : workspace }
    }

    /// Bring back the lanes open at the last quit, each resuming its last
    /// conversation when started; or, failing that, the workspace marked to
    /// open at launch. Returns whether anything was added.
    @discardableResult
    public func restoreAtLaunch() -> Bool {
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
    public func rename(_ id: AgentLane.ID, to name: String?) {
        let name = name?.trimmingCharacters(in: .whitespaces)
        let value = name?.isEmpty == false ? name : nil
        sessions[id]?.customTitle = value
        if let value { layout.names[id] = value } else { layout.names.removeValue(forKey: id) }
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
        if source.directory == nil { lane.directory = URL(fileURLWithPath: session.currentDirectory) }
        let taken = Set(sessions.values.map(\.title))
        let name = session.title.nextCopyName(taken: taken)
        let added = add(lane, focus: focus, after: id)
        rename(lane.id, to: name)
        return added
    }

    /// Run a lane the person opened on another backend, keeping its name,
    /// section and place. Its terminal restarts.
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
            return
        }
        guard let backend = backends[lane.backendID] ?? backends["shell"] ?? Optional(CommandLaneBackend.shell) else { return }
        let session = AgentLaneSession(lane: lane, backend: backend)
        let id = lane.id
        session.onWantsAttention = { [weak self] session in self?.laneWantsAttention(session) }
        session.customTitle = layout.names[id]
        session.onShortcut = { [weak self] shortcut in self?.handle(shortcut, from: id) ?? false }
        session.onSectionFromAgent = { [weak self] section in
            guard let self, self.layout.assignments[id] == nil, self.layout.section(of: lane) != section else { return }
            self.layout.move(id, to: section)
        }
        sessions[lane.id] = session
    }

    /// Show a lane, attaching it the first time or after it ended. Opening a
    /// lane that is already attached only shows it.
    public func open(_ id: AgentLane.ID, focus: Bool = true) {
        guard let session = sessions[id] else { return }
        recordVisit(id)
        if id == splitID { splitID = selectedID == id ? nil : selectedID }
        selectedID = id
        start(session)
        if focus { session.wantsFocus = true }
        updateShown()
    }

    public func openSelected(focus: Bool = true) {
        guard let id = selectedID ?? lanes.first?.id else { return }
        open(id, focus: focus)
    }

    /// The lanes as the list shows them, grouped.
    public var groups: [LaneGroup] {
        layout.groups(for: lanes) { [sessions] lane in sessions[lane.id]?.lastActivity }
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
        layout.collapsed = collapsed ? Set(layout.orderedSections(for: lanes) + [LaneLayout.pinnedSection]) : []
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
    public func stop(_ id: AgentLane.ID) {
        guard let session = sessions[id], session.backend.canStop else { return }
        session.detach()
        session.backend.stop(session.lane)
        statusFeed?.reload()
    }

    /// Whether the lane's session can be stopped from here.
    public func canStop(_ id: AgentLane.ID) -> Bool { sessions[id]?.backend.canStop == true }

    /// End and remove a lane the person opened, stopping its session too
    /// when ``Configuration/closeStopsLane`` is on.
    public func close(_ id: AgentLane.ID) {
        guard let index = lanes.firstIndex(where: { $0.id == id }), lanes[index].isClosable else { return }
        if configuration.closeStopsLane, let session = sessions[id], session.backend.canStop {
            session.backend.stop(session.lane)
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
        defer { didCloseLane?(closed, .remove) }
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
        }
        return true
    }

    private func apply(_ records: [LaneStatus]) {
        for session in sessions.values {
            let match = session.lane.statusMatch ?? session.backend.statusMatch(for: session.lane)
            session.update(record: match.find(in: records))
        }
        objectWillChange.send()
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
        }
        objectWillChange.send()
    }

    private func updateShown() {
        for (id, session) in sessions {
            session.isShown = isShowing && (id == selectedID || id == splitID)
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
    public var fontOffset: String { prefix + "fontOffset" }
    public var layout: String { prefix + "layout" }
    public var newLaneBackend: String { prefix + "newLaneBackend" }
    public var newLaneCommand: String { prefix + "newLaneCommand" }
    public var openAtLaunch: String { prefix + "openAtLaunch" }
    public var reopenLast: String { prefix + "reopenLast" }
    public var dockHeight: String { prefix + "dockHeight" }
    public var dockMaximized: String { prefix + "dockMaximized" }
    public var dockListWidth: String { prefix + "dockListWidth" }
}
