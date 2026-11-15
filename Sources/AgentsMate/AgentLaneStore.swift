import AppKit
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

        public init(termProgram: String, environment: [String: String] = [:],
                    baseFontSize: CGFloat = NSFont.systemFontSize,
                    scrollback: Int = 20_000, shortcuts: TerminalShortcut.Set = .fixedLanes,
                    defaultsPrefix: String = "agentsmate.", highlightsOrphans: Bool = false,
                    closeStopsLane: Bool = true,
                    sessionFileDirectory: URL? = FileManager.default.temporaryDirectory
                        .appendingPathComponent("agentsmate-sessions", isDirectory: true),
                    cycleSkipsUnstarted: Bool = false) {
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
        statusFeed?.start()
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

    // MARK: Naming, duplicating, switching agent

    /// Give a row a name of the person's own; nil returns to the automatic name.
    public func rename(_ id: AgentLane.ID, to name: String?) {
        let name = name?.trimmingCharacters(in: .whitespaces)
        let value = name?.isEmpty == false ? name : nil
        sessions[id]?.customTitle = value
        if let value { layout.names[id] = value } else { layout.names.removeValue(forKey: id) }
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
        if id == splitID { splitID = selectedID == id ? nil : selectedID }
        selectedID = id
        session.start(configuration: configuration, font: font)
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
            sessions[other]?.start(configuration: configuration, font: font)
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
        case .maximize, .togglePanel: return false
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
}
