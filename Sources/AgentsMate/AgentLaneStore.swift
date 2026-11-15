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
        public var font: NSFont
        public var scrollback: Int
        /// The shortcuts a focused terminal answers itself.
        public var shortcuts: TerminalShortcut.Set
        /// Prefix for the saved list width, collapse, filters and selection.
        public var defaultsPrefix: String

        public init(termProgram: String, environment: [String: String] = [:],
                    font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular),
                    scrollback: Int = 20_000, shortcuts: TerminalShortcut.Set = .fixedLanes,
                    defaultsPrefix: String = "agentsmate.") {
            self.termProgram = termProgram
            self.environment = environment
            self.font = font
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

    public var configuration: Configuration
    public let keys: AgentsModeKeys
    public let statusFeed: LaneStatusFeed?
    /// What ⌘T opens, when the app allows it.
    public var onNewLane: (() -> Void)?

    private var backends: [String: any LaneBackend] = [:]
    private let defaults: UserDefaults
    private var feedSubscription: AnyCancellable?

    public init(configuration: Configuration, backends: [any LaneBackend],
                statusFeed: LaneStatusFeed? = LaneStatusFeed(), defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.keys = AgentsModeKeys(prefix: configuration.defaultsPrefix)
        self.statusFeed = statusFeed
        self.defaults = defaults
        for backend in backends { self.backends[backend.id] = backend }
        self.selectedID = defaults.string(forKey: keys.selectedLane)
        feedSubscription = statusFeed?.$records.sink { [weak self] records in
            MainActor.assumeIsolated { self?.apply(records) }
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
    public func add(_ lane: AgentLane, focus: Bool = true) -> AgentLaneSession? {
        if sessions[lane.id] == nil {
            lanes.append(lane)
            makeSession(for: lane)
            apply(statusFeed?.records ?? [])
        }
        open(lane.id, focus: focus)
        return sessions[lane.id]
    }

    private func makeSession(for lane: AgentLane) {
        if let existing = sessions[lane.id] {
            existing.update(lane: lane)
            return
        }
        guard let backend = backends[lane.backendID] ?? backends["shell"] ?? Optional(CommandLaneBackend.shell) else { return }
        let session = AgentLaneSession(lane: lane, backend: backend)
        let id = lane.id
        session.onShortcut = { [weak self] shortcut in self?.handle(shortcut, from: id) ?? false }
        sessions[lane.id] = session
    }

    /// Show a lane, attaching it the first time or after it ended. Opening a
    /// lane that is already attached only shows it.
    public func open(_ id: AgentLane.ID, focus: Bool = true) {
        guard let session = sessions[id] else { return }
        if id == splitID { splitID = selectedID == id ? nil : selectedID }
        selectedID = id
        session.start(configuration: configuration)
        if focus { session.wantsFocus = true }
        updateShown()
    }

    public func openSelected(focus: Bool = true) {
        guard let id = selectedID ?? lanes.first?.id else { return }
        open(id, focus: focus)
    }

    public func open(index: Int) {
        guard lanes.indices.contains(index) else { return }
        open(lanes[index].id)
    }

    public func detach(_ id: AgentLane.ID) { sessions[id]?.detach() }

    public func reattach(_ id: AgentLane.ID) {
        guard let session = sessions[id] else { return }
        session.detach()
        open(id)
    }

    /// End and remove a lane the person opened.
    public func close(_ id: AgentLane.ID) {
        guard let index = lanes.firstIndex(where: { $0.id == id }), lanes[index].isClosable else { return }
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
        guard !lanes.isEmpty else { return }
        let index = lanes.firstIndex { $0.id == selectedID } ?? 0
        open(index: (index + offset + lanes.count) % lanes.count)
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
            sessions[other]?.start(configuration: configuration)
            splitID = other
        }
        updateShown()
    }

    public func clearSelected() { selected?.view.clearScreen() }

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
        case .maximize: return false
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
    public var listWidth: String { prefix + "listWidth" }
    public var listCollapsed: String { prefix + "listCollapsed" }
    public var filterOpen: String { prefix + "filterOpen" }
    public var filterRunning: String { prefix + "filterRunning" }
    public var filterWaiting: String { prefix + "filterWaiting" }
}
