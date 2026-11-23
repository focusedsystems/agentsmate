import Foundation
import AgentsMateStatus

/// What Agents mode shows the first time it comes on screen after launch.
public enum AgentsLaunchDestination: Sendable, Equatable {
    /// Home: the overview of every active session. Nothing is attached
    /// until the person picks a row.
    case home
    /// The selected lane, reattached when its session already runs
    /// (``AgentLaneStore/openSelectedOnShow(focus:)``).
    case selectedLane
}

/// A section of Home.
public enum AgentHomeSection: Int, CaseIterable, Sendable, Identifiable {
    /// Waiting for an answer or a permission.
    case needsYou
    /// The agent is working.
    case working
    /// Alive but quiet, or finished a turn recently.
    case recent

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .needsYou: "Needs You"
        case .working: "Working"
        case .recent: "Idle & Done"
        }
    }
}

/// What Home looks at in one row, kept apart from the session so the
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

/// How Home sorts sessions into its sections.
public enum AgentHome {
    /// How long a finished session that is no longer running stays on Home.
    public static let recentWindow: TimeInterval = 24 * 60 * 60

    /// The section a row belongs in, or nil when Home leaves it out: a
    /// lane with nothing running and no recent news. Needs You and Working
    /// count the same rows as the sidebar's Needs You and Running filters.
    public static func section(for item: AgentHomeItem, now: Date = Date()) -> AgentHomeSection? {
        if LaneStatusFilter.wantsYou(item.status) { return .needsYou }
        if item.status == .running { return .working }
        if item.isActive || item.unread { return .recent }
        if item.status == .done || item.status == .idle,
           let last = item.lastActivity, now.timeIntervalSince(last) <= recentWindow {
            return .recent
        }
        return nil
    }

    /// The rows in their sections, in section order, leaving out empty
    /// sections. Within a section the most recent activity comes first;
    /// rows with no activity follow, in the order given.
    public static func grouped(_ items: [AgentHomeItem], now: Date = Date())
        -> [(section: AgentHomeSection, items: [AgentHomeItem])] {
        var buckets: [AgentHomeSection: [(offset: Int, item: AgentHomeItem)]] = [:]
        for (offset, item) in items.enumerated() {
            if let section = section(for: item, now: now) { buckets[section, default: []].append((offset, item)) }
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

    /// The totals Home's header shows.
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
            }
        }
        return totals
    }

    /// The line a row shows under its title: the question or permission
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

/// Whether Home is still filling in: hosts that have not answered yet, and
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
    /// Home is what the detail area shows now.
    public var isHomeShown: Bool { configuration.showsHome && showingHome }

    /// Every row Home could list, in the sidebar's order: the app's lanes
    /// and the detached sessions found in its folders.
    var homeSessions: [AgentLaneSession] { displayOrder.compactMap { sessions[$0.id] } }

    static func homeItem(_ session: AgentLaneSession) -> AgentHomeItem {
        AgentHomeItem(id: session.id, status: session.status, isActive: session.isActive,
                      unread: session.needsAttention, lastActivity: session.lastActivity)
    }

    /// The section name Home shows beside a row's title.
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
        loading.findingSessions = configuration.findsDetachedSessions
            && (sweepingSessions || lastSweep == .distantPast)
        return loading
    }
}

public extension AgentsModeKeys {
    /// Whether Home was showing, so it comes back as the person left it.
    var showingHome: String { prefix + "showingHome" }
}
