import Foundation
import AgentsMateStatus

/// What Agents mode shows the first time it comes on screen after launch.
public enum AgentsLaunchDestination: Sendable, Equatable {
    /// All Agents: the board of every active session. Nothing is attached
    /// until the person picks a card.
    case home
    /// The selected lane, reattached when its session already runs
    /// (``AgentLaneStore/openSelectedOnShow(focus:)``).
    case selectedLane
}

/// A column of the All Agents board.
public enum AgentHomeSection: Int, CaseIterable, Sendable, Identifiable {
    /// Waiting for an answer or a permission.
    case needsYou
    /// The agent is working.
    case working
    /// Alive but quiet, or finished a turn recently.
    case recent
    /// A lane with nothing running: shown only when the board lists every
    /// lane, not just the active ones.
    case notRunning

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .needsYou: "Needs You"
        case .working: "Working"
        case .recent: "Idle & Done"
        case .notRunning: "Not Running"
        }
    }
}

/// What All Agents looks at in one card, kept apart from the session so the
/// grouping can be tested without terminals.
public struct AgentHomeItem: Equatable, Sendable, Identifiable {
    public var id: AgentLane.ID
    public var status: LaneDisplayStatus
    /// Attached here, or running somewhere (``AgentLaneSession/isActive``).
    public var isActive: Bool
    /// The row's unread mark.
    public var unread: Bool
    public var lastActivity: Date?

    public init(id: AgentLane.ID, status: LaneDisplayStatus, isActive: Bool, unread: Bool = false,
                lastActivity: Date? = nil) {
        self.id = id
        self.status = status
        self.isActive = isActive
        self.unread = unread
        self.lastActivity = lastActivity
    }
}

/// How All Agents sorts sessions into its columns. (Home was its first
/// name; the types and the saved keys keep it.)
public enum AgentHome {
    /// How long a finished session that is no longer running stays on the board.
    public static let recentWindow: TimeInterval = 24 * 60 * 60

    /// The column a card belongs in, or nil when the board leaves it out: a
    /// lane with nothing running and no recent news. Needs You and Working
    /// count the same rows as the sidebar's Needs You and Running filters.
    ///
    /// With `includesNotRunning`, the board lists every lane: one it would
    /// leave out goes in Not Running instead.
    public static func section(for item: AgentHomeItem, now: Date = Date(),
                               includesNotRunning: Bool = false) -> AgentHomeSection? {
        if LaneStatusFilter.wantsYou(item.status) { return .needsYou }
        if item.status == .running { return .working }
        if item.isActive || item.unread { return .recent }
        if item.status == .done || item.status == .idle,
           let last = item.lastActivity, now.timeIntervalSince(last) <= recentWindow {
            return .recent
        }
        return includesNotRunning ? .notRunning : nil
    }

    /// The rows in their sections, in section order, leaving out empty
    /// sections. Within a section the most recent activity comes first;
    /// rows with no activity follow, in the order given.
    public static func grouped(_ items: [AgentHomeItem], now: Date = Date(), includesNotRunning: Bool = false)
        -> [(section: AgentHomeSection, items: [AgentHomeItem])] {
        var buckets: [AgentHomeSection: [(offset: Int, item: AgentHomeItem)]] = [:]
        for (offset, item) in items.enumerated() {
            if let section = section(for: item, now: now, includesNotRunning: includesNotRunning) {
                buckets[section, default: []].append((offset, item))
            }
        }
        return AgentHomeSection.allCases.compactMap { section in
            guard let rows = buckets[section], !rows.isEmpty else { return nil }
            let sorted = rows.sorted { a, b in
                switch (a.item.lastActivity, b.item.lastActivity) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }
            return (section, sorted.map(\.item))
        }
    }

    /// Every column in board order, empty ones included, with the same
    /// order inside each as ``grouped(_:now:includesNotRunning:)``. Not
    /// Running is a column only with `includesNotRunning`.
    public static func columns(_ items: [AgentHomeItem], now: Date = Date(), includesNotRunning: Bool = false)
        -> [(section: AgentHomeSection, items: [AgentHomeItem])] {
        let groups = grouped(items, now: now, includesNotRunning: includesNotRunning)
        return AgentHomeSection.allCases.filter { includesNotRunning || $0 != .notRunning }.map { section in
            (section, groups.first { $0.section == section }?.items ?? [])
        }
    }

    /// A move on the board with the arrow keys.
    public enum Move: Sendable { case up, down, left, right }

    /// The card a move lands on. Up and down stay in the column; left and
    /// right go to the nearest column that has cards, at the same position
    /// or its last card. With nothing selected (or the selection filtered
    /// away) any move lands on the first card.
    public static func move(_ move: Move, from selection: AgentLane.ID?,
                            in columns: [[AgentLane.ID]]) -> AgentLane.ID? {
        guard let selection,
              let col = columns.firstIndex(where: { $0.contains(selection) }),
              let row = columns[col].firstIndex(of: selection) else {
            return columns.first { !$0.isEmpty }?.first
        }
        switch move {
        case .up: return columns[col][max(0, row - 1)]
        case .down: return columns[col][min(columns[col].count - 1, row + 1)]
        case .left, .right:
            let step = move == .left ? -1 : 1
            var next = col + step
            while columns.indices.contains(next) {
                if !columns[next].isEmpty { return columns[next][min(row, columns[next].count - 1)] }
                next += step
            }
            return selection
        }
    }

    /// The totals the board's header shows.
    public struct Totals: Equatable, Sendable {
        public var needsYou = 0
        public var working = 0
        public var recent = 0
    }

    public static func totals(_ groups: [(section: AgentHomeSection, items: [AgentHomeItem])]) -> Totals {
        var totals = Totals()
        for group in groups {
            switch group.section {
            case .needsYou: totals.needsYou = group.items.count
            case .working: totals.working = group.items.count
            case .recent: totals.recent = group.items.count
            case .notRunning: break
            }
        }
        return totals
    }

    /// The line a card shows under its title: the question or permission
    /// the agent is waiting on, else what it is doing or did.
    @MainActor
    static func detail(for session: AgentLaneSession) -> String? {
        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        let note = nonEmpty(session.note?.text)
        let summary = nonEmpty(session.summary)
        if LaneStatusFilter.wantsYou(session.status) {
            let question = session.lastReply.flatMap(LaneTranscript.finalQuestion(in:))
            return nonEmpty(session.record?.message) ?? nonEmpty(question) ?? note ?? summary
        }
        if session.status == .running { return note ?? summary ?? nonEmpty(session.task) }
        return summary ?? note ?? nonEmpty(LaneRow.hoverReply(session.lastReply, limit: 200))
    }
}

/// Whether All Agents is still filling in: hosts that have not answered yet, and
/// the first look for detached sessions.
public struct AgentHomeLoading: Equatable, Sendable {
    public enum HostState: Equatable, Sendable { case asking, answered, unreachable }

    public struct Host: Equatable, Sendable, Identifiable {
        public var name: String
        public var state: HostState
        public var id: String { name }
    }

    /// Every host asked what it has running, with how far each has got.
    public var hosts: [Host] = []
    /// Backends are being asked for sessions no row attaches.
    public var findingSessions = false

    public var hostsAnswered: Int { hosts.filter { $0.state != .asking }.count }
    public var isLoading: Bool { findingSessions || hosts.contains { $0.state == .asking } }
}

extension AgentLaneStore {
    /// All Agents is what the detail area shows now.
    public var isHomeShown: Bool { configuration.showsHome && showingHome }

    /// Every session All Agents could show, in the sidebar's order: the app's lanes
    /// and the detached sessions found in its folders.
    var homeSessions: [AgentLaneSession] { displayOrder.compactMap { sessions[$0.id] } }

    static func homeItem(_ session: AgentLaneSession) -> AgentHomeItem {
        AgentHomeItem(id: session.id, status: session.status, isActive: session.isActive,
                      unread: session.needsAttention, lastActivity: session.lastActivity)
    }

    /// The section name All Agents shows on a card.
    func homeArea(of lane: AgentLane) -> String? {
        if let owner = detachedOwners[lane.id], let ownerLane = lanes.first(where: { $0.id == owner }) {
            return layout.section(of: ownerLane)
        }
        if isDetached(lane.id) { return "Detached" }
        return layout.section(of: lane)
    }

    /// How far the hosts and the session sweep have got.
    public var homeLoading: AgentHomeLoading {
        var loading = AgentHomeLoading()
        if configuration.hostSessions != nil, let hosts = listingHosts {
            loading.hosts = HostSessions.askedHosts(hosts).map { host in
                let state: AgentHomeLoading.HostState = hostListings[host.name] != nil ? .answered
                    : unknownHosts.contains(host.name) ? .unreachable : .asking
                return .init(name: host.name, state: state)
            }
        }
        loading.findingSessions = configuration.findsDetachedSessions && !firstSweepFinished
        return loading
    }

    /// The live snapshot was read at launch: All Agents shows the board at
    /// once, from it, and fills in as the hosts answer.
    public var startsFromLiveSnapshot: Bool { liveSnapshotRead }
}

public extension AgentsModeKeys {
    /// Whether All Agents was showing, so it comes back as the person left it.
    var showingHome: String { prefix + "showingHome" }
}
