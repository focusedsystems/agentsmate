import AppKit
import SwiftUI
import Combine
import Foundation
import AgentsMateStatus

extension LaneDisplayStatus {
    /// The state name ``DisplayedExport`` uses for a row, from the same status the row's dot shows.
    var exportState: DisplayedExport.State {
        switch self {
        case .notOpened: .notAttached
        case .attached: .active
        case .running: .working
        case .waitingForInput, .permissionRequested: .needsYou
        case .done, .idle: .idle
        case .detached: .stopped
        }
    }
}

extension AgentLaneStore.Configuration {
    /// `~/.local/state/agentsmate/<bundle id>/displayed.json` for a running
    /// app bundle (``DisplayedExport/standardURL(bundleID:environment:)``);
    /// nil outside one, so a test host or a command-line tool writes nothing.
    public static var defaultDisplayedExportFile: URL? {
        guard let id = Bundle.main.bundleIdentifier, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return DisplayedExport.standardURL(bundleID: id)
    }

    /// The commit of AgentsMate the app was built from: the
    /// `AgentsMateCommit` key of its Info.plist, when it has one.
    public static var bundledAgentsMateCommit: String? {
        (Bundle.main.object(forInfoDictionaryKey: "AgentsMateCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Keeps ``DisplayedExport`` up to date on disk. A change anywhere in what
/// the lists show starts a timer; when it fires, one export is worked out,
/// and written only if it differs from the last one. Encoding and the file
/// write happen off the main actor.
@MainActor
final class DisplayedExporter {
    private weak var store: AgentLaneStore?
    let url: URL
    /// How long changes are gathered before one write.
    let delay: TimeInterval
    private var pending: Task<Void, Never>?
    private var last: DisplayedExport?
    private var storeSubscription: AnyCancellable?
    private var sessionsSubscription: AnyCancellable?
    private var defaultsSubscription: AnyCancellable?
    private var sessionSubscriptions: [AnyCancellable] = []
    private let queue = DispatchQueue(label: "agentsmate.displayed-export", qos: .utility)
    /// How many files have been written, for tests.
    private(set) var writes = 0

    init(store: AgentLaneStore, url: URL, delay: TimeInterval = 1) {
        self.store = store
        self.url = url
        self.delay = delay
        // The store announces lane, layout, selection and session-list changes.
        storeSubscription = store.objectWillChange.sink { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        // Each session announces the few things a row shows: not its terminal output.
        sessionsSubscription = store.$sessions.sink { [weak self] sessions in
            MainActor.assumeIsolated { self?.watch(Array(sessions.values)) }
        }
        // The filter chips and the sidebar's shape live in UserDefaults.
        defaultsSubscription = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: store.defaults)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.changed() } }
        changed()
    }

    private func watch(_ sessions: [AgentLaneSession]) {
        sessionSubscriptions = sessions.map { session in
            Publishers.MergeMany([
                session.$record.dropFirst().map { _ in }.eraseToAnyPublisher(),
                session.$isStarted.dropFirst().map { _ in }.eraseToAnyPublisher(),
                session.$hasExited.dropFirst().map { _ in }.eraseToAnyPublisher(),
                session.$isPresent.dropFirst().map { _ in }.eraseToAnyPublisher(),
                session.$liveHint.dropFirst().map { _ in }.eraseToAnyPublisher(),
                session.$needsAttention.dropFirst().map { _ in }.eraseToAnyPublisher(),
                session.$customTitle.dropFirst().map { _ in }.eraseToAnyPublisher(),
                session.$metadata.dropFirst().map { _ in }.eraseToAnyPublisher(),
                session.$programTitle.dropFirst().map { _ in }.eraseToAnyPublisher(),
            ]).sink { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        }
        changed()
    }

    /// Something shown may have changed. Changes within ``delay`` of the first share one write.
    func changed() {
        guard pending == nil else { return }
        pending = Task { [weak self, delay] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Work out the export now and write it if it differs from the last one.
    func flush() {
        pending = nil
        guard let store else { return }
        let now = Date()
        var export = store.displayedExport()
        if let last, last.sameContent(as: export) { return }
        last = export
        export.writtenAt = now
        let url = url
        queue.async { [weak self] in
            guard let data = try? export.encoded() else { return }
            do { try DisplayedExport.write(data, to: url) } catch { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.writes += 1 } }
        }
    }
}

extension AgentLaneStore {
    func startDisplayedExport(delay: TimeInterval = 1) {
        displayedExporter = nil
        guard let url = configuration.displayedExportFile else { return }
        displayedExporter = DisplayedExporter(store: self, url: url, delay: delay)
    }

    /// The status chips that are on, as the sidebar and All Agents read them.
    var activeStatusFilters: Set<LaneStatusFilter> {
        var on: Set<LaneStatusFilter> = []
        if defaults.bool(forKey: keys.filterOpen) { on.insert(.active) }
        if defaults.bool(forKey: keys.filterRunning) { on.insert(.running) }
        if defaults.bool(forKey: keys.filterWaiting) { on.insert(.needsYou) }
        if defaults.bool(forKey: keys.filterIdle) { on.insert(.idle) }
        if defaults.bool(forKey: keys.filterUnread) { on.insert(.unread) }
        return on
    }

    private func backendKind(_ backend: (any LaneBackend)?, id: String) -> String {
        if backend is ClaudeBackgroundLaneBackend { return ClaudeBackgroundLaneBackend.kind }
        if let command = backend as? CommandLaneBackend {
            if command.tmuxSessions != nil { return TmuxLaneSessions.kind }
            return command.command.trimmingCharacters(in: .whitespaces).isEmpty ? "shell" : "command"
        }
        return id
    }

    private func displayedRow(_ lane: AgentLane, session: AgentLaneSession, section: String?, collapsed: Bool,
                              nested: Bool, column: String?) -> DisplayedExport.Row {
        let backend = self.backend(id: lane.backendID)
        let agent = agentKind(ofBackend: lane.backendID)?.agent
            ?? (backend is ClaudeBackgroundLaneBackend ? "claude" : nil)
        let running = session.record.flatMap { $0.state == .ended ? nil : $0 }
        let parallel = parallelOwner(of: lane.id) != nil
        return DisplayedExport.Row(
            section: section, title: session.title, laneID: lane.id,
            backend: backendKind(backend, id: lane.backendID), agent: agent,
            sessionID: lane.agentSessionID ?? ownedSession(for: lane)?.agentID, attachedSessionID: running?.agentID ?? running?.sessionID,
            sessionName: lane.sessionName ?? backend?.sessionName(for: lane),
            host: liveHost(for: lane) ?? backend.flatMap(DetachedSessions.laneHost) ?? lane.host,
            folder: lane.directory?.path, state: session.status.exportState, attached: session.isAttached,
            selected: !isHomeShown && selectedID == lane.id, isParallel: parallel,
            isTopLevel: !(nested && parallel), collapsed: collapsed, column: column)
    }

    /// Everything the sidebar and All Agents show now, in the order they show it.
    /// Rows the app's scope keeps out never become lanes, and rows the search
    /// and filters hide are skipped here as the views skip them.
    func displayedExport(now: Date = Date()) -> DisplayedExport {
        typealias Sidebar = AgentLaneSidebar<EmptyView>
        let snapshot = listSnapshot
        let filters = activeStatusFilters
        let headings = defaults.object(forKey: keys.showsSectionHeadings) as? Bool ?? configuration.showsSectionHeadings
        let placement = defaults.string(forKey: keys.parallelSessions) ?? configuration.parallelSessions.rawValue
        let nested = placement == ParallelSessionPlacement.nested.rawValue
        let sidebarQuery = displayedSidebarSearch.trimmingCharacters(in: .whitespaces)
        let filtering = !sidebarQuery.isEmpty || !filters.isEmpty
        let flat = Sidebar.isFlat(snapshot, showsHeadings: headings)
        let visible = Set(Sidebar.visibleLanes(store: self, query: displayedSidebarSearch, filters: filters).map(\.id))
        var rows: [DisplayedExport.Row] = []
        for group in Sidebar.displayedGroups(snapshot, flat: flat, visible: visible, filtering: filtering) {
            // A group draws a heading unless the list is flat or the lanes are in no section.
            let heading = (flat || group.section == nil) && !group.isPinned && !group.isDetached ? nil : group.title
            let folded = heading != nil && !filtering && layout.collapsed.contains(group.collapseKey)
            for lane in group.lanes {
                guard let session = self.session(for: lane) else { continue }
                rows.append(displayedRow(lane, session: session, section: heading, collapsed: folded,
                                         nested: nested && !group.isDetached, column: nil))
            }
        }
        var cards: [DisplayedExport.Row] = []
        let activeOnly = filters.contains(.active)
        if configuration.showsHome {
            for column in AgentHomeView.columns(store: self, query: displayedHomeSearch, filters: filters,
                                                activeOnly: activeOnly) {
                let name: String
                switch column.section {
                case .needsYou: name = "needs_you"
                case .working: name = "working"
                case .recent: name = "idle_or_done"
                case .notRunning: name = "not_running"
                }
                for item in column.items {
                    guard let session = sessions[item.id] else { continue }
                    var card = displayedRow(session.lane, session: session, section: homeArea(of: session.lane),
                                            collapsed: false, nested: false, column: name)
                    card.selected = false
                    cards.append(card)
                }
            }
        }
        let totals = AgentHome.totals(AgentHome.grouped(homeSessions.map(AgentLaneStore.homeItem), now: now))
        let info = Bundle.main.infoDictionary
        let search = displayedHomeSearch.trimmingCharacters(in: .whitespaces)
        return DisplayedExport(
            app: .init(bundleID: Bundle.main.bundleIdentifier ?? "", version: info?["CFBundleShortVersionString"] as? String,
                       build: info?["CFBundleVersion"] as? String,
                       agentsMateCommit: configuration.agentsMateCommit ?? Configuration.bundledAgentsMateCommit),
            lastDiscoveryFinishedAt: lastDiscoveryFinishedAt,
            filter: .init(show: activeOnly ? "active" : "all",
                          statuses: LaneStatusFilter.allCases.filter(filters.contains).map(Self.exportName),
                          search: search.isEmpty ? nil : search, sidebarSearch: sidebarQuery.isEmpty ? nil : sidebarQuery),
            counts: .init(needsYou: totals.needsYou, working: totals.working, idleOrDone: totals.recent),
            rows: rows, allAgents: cards)
    }

    private static func exportName(_ filter: LaneStatusFilter) -> String {
        filter == .needsYou ? "needs_you" : filter.rawValue
    }
}
