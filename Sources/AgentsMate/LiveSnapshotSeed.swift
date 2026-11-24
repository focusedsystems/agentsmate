import Foundation
import AgentsMateStatus

/// What the live snapshot (``LiveSessionSnapshot``) said about a lane's
/// session, shown until its host answers. It never starts or attaches
/// anything; the real status, presence and host listings replace it.
public struct LiveSessionHint: Equatable, Sendable {
    public var state: LiveSessionSnapshot.State
    public var lastActivity: Date?
    /// The host the session runs on, as the snapshot names it.
    public var host: String?
    /// When that host last reported.
    public var seen: Date?
    /// The host has not reported for a while: this is what it had then.
    public var isStale: Bool
    /// The tmux session, or the background session's short id, the hint is for.
    public var tmuxName: String?
    public var agentID: String?

    public init(state: LiveSessionSnapshot.State, lastActivity: Date? = nil, host: String? = nil,
                seen: Date? = nil, isStale: Bool = false, tmuxName: String? = nil, agentID: String? = nil) {
        self.tmuxName = tmuxName
        self.agentID = agentID
        self.state = state
        self.lastActivity = lastActivity
        self.host = host
        self.seen = seen
        self.isStale = isStale
    }

    /// The row's status while the hint stands.
    public var displayStatus: LaneDisplayStatus {
        switch state {
        case .working: .running
        case .needsYou: .waitingForInput
        case .idle, .detached: .idle
        case .done: .done
        }
    }

    /// Whether the session was running when its host last looked.
    public var isAlive: Bool { state != .done }

    /// Whether a host's own listing still has the session.
    func isListed(in listing: HostSessionListing) -> Bool {
        if let agentID, listing.claude.contains(where: { $0.agentID == agentID }) { return true }
        if let tmuxName, listing.tmux.contains(tmuxName) { return true }
        return false
    }
}

/// Matching the live snapshot against the rows. Only exact matches count: the
/// app lane id the watcher recorded for a session, the short id a row holds,
/// or the tmux name a row's backend attaches, and always on the row's own
/// host. A folder never matches, so two lanes in one folder stay apart.
enum LiveSnapshotSeed {
    typealias Session = LiveSessionSnapshot.Session

    /// The session `lane` holds, from those on `host`, or nil.
    static func session(for lane: AgentLane, backend: any LaneBackend, host: String?,
                        in snapshot: LiveSessionSnapshot) -> Session? {
        let candidates: [Session]
        if let host { candidates = snapshot.hosts[host]?.sessions ?? [] } else { candidates = [] }
        // A row that holds a background session's id takes that session only:
        // a watcher that tied another session to the row's id by folder is not believed.
        if let byLane = candidates.first(where: { $0.lane == lane.id }),
           lane.agentSessionID.map({ $0.isEmpty || byLane.agentID == $0 }) ?? true { return byLane }
        if let held = lane.agentSessionID, !held.isEmpty,
           let byID = candidates.first(where: { $0.agentID == held }) {
            return byID
        }
        if let name = DetachedSessions.laneName(lane, backend: backend), !name.isEmpty,
           let byName = candidates.first(where: { $0.kind == TmuxLaneSessions.kind && $0.name == name }) {
            return byName
        }
        return nil
    }

    static func hint(for lane: AgentLane, backend: any LaneBackend, host: String?,
                     in snapshot: LiveSessionSnapshot, now: Date = Date()) -> LiveSessionHint? {
        guard let host, let found = session(for: lane, backend: backend, host: host, in: snapshot) else { return nil }
        return LiveSessionHint(state: found.state, lastActivity: found.lastActivity, host: host,
                               seen: snapshot.hosts[host]?.seen, isStale: snapshot.isStale(host, now: now),
                               tmuxName: found.kind == TmuxLaneSessions.kind ? found.name : nil,
                               agentID: found.kind == "background" ? found.agentID : nil)
    }

    /// The sessions on this Mac (`selfName`) the snapshot lists that a sweep
    /// would add as found rows, as that sweep would report them, so their
    /// rows can show before it comes back and keep the same ids after.
    ///
    /// Only with a scope: a snapshot holds every app's sessions, so an app
    /// that has not said which folders are its own is shown none of them.
    /// A session the watcher tied to an app lane is some lane's own and is
    /// left to that lane. Sessions that have ended are left out.
    static func found(in snapshot: LiveSessionSnapshot, selfName: String?, backends: [any LaneBackend],
                      scope: (@Sendable (_ directory: String?, _ host: String?) -> Bool)?) -> [DetachedSessions.Found] {
        guard let scope, let selfName, let sessions = snapshot.hosts[selfName]?.sessions else { return [] }
        let ordered = backends.sorted { $0.id < $1.id }
        var out: [DetachedSessions.Found] = []
        for item in sessions where item.lane == nil && item.state != .done && scope(item.folder, nil) {
            switch item.kind {
            case "background":
                guard let id = item.agentID, HostSessions.isValidAgentID(id) else { continue }
                let session = DiscoveredSession(kind: ClaudeBackgroundLaneBackend.kind, name: item.name,
                                                directory: item.folder, sessionID: item.sessionID, agentID: id)
                guard let backend = ordered.first(where: { backend in
                    guard let claude = backend as? ClaudeBackgroundLaneBackend, claude.discoversSessions else { return false }
                    return claude.isRelevant.map { $0(session) } ?? claude.isLaneSession?(item.name) ?? true
                }) else { continue }
                out.append(.init(backendID: backend.id, session: session))
            case TmuxLaneSessions.kind:
                guard TmuxLaneSessions.isValidSessionName(item.name) else { continue }
                let session = DiscoveredSession(kind: TmuxLaneSessions.kind, name: item.name, directory: item.folder,
                                                attachedClients: item.attached)
                guard let backend = ordered.first(where: { backend in
                    guard let tmux = (backend as? CommandLaneBackend)?.tmuxSessions, tmux.host == nil else { return false }
                    return tmux.isLaneSession(session)
                }) else { continue }
                out.append(.init(backendID: backend.id, session: session))
            default:
                continue
            }
        }
        return out
    }
}
