import Foundation

/// Keeps a row's name and its agent's session title the same, both ways,
/// without either change echoing back.
///
/// - Row to session: a name the person gave the row is queued here and typed
///   into the agent as `/rename` the next time the agent sits idle at an empty
///   input line. Until the agent's title shows that name (or ``awaitingWindow``
///   passes), the session's old title never overwrites the row.
/// - Session to row: a title read from the agent that is not the one already
///   reconciled becomes the row's name, once it has been read the same twice
///   in a row, so a title in the middle of changing is not taken early.
///
/// Adopting a title only sets the row's name; it never queues a rename, so a
/// rename in either direction ends once both sides agree.
struct LaneTitleSync: Equatable {
    /// How long a typed rename may take to show up in the agent's title.
    static let awaitingWindow: TimeInterval = 30

    /// The last session title that is already settled with the row.
    var acknowledged: String?
    /// A row name waiting for the agent to be idle.
    private(set) var pending: String?
    private var awaiting: (name: String, until: Date)?
    private var candidate: String?

    init(acknowledged: String? = nil, pending: String? = nil) {
        self.acknowledged = acknowledged
        self.pending = pending
    }

    static func == (a: Self, b: Self) -> Bool {
        a.acknowledged == b.acknowledged && a.pending == b.pending && a.awaiting?.name == b.awaiting?.name
            && a.candidate == b.candidate
    }

    /// Whether two names are the same once flattened to one plain line.
    static func same(_ a: String?, _ b: String?) -> Bool {
        LaneRename.cleanName(a ?? "") == LaneRename.cleanName(b ?? "")
    }

    var hasPending: Bool { pending != nil }

    /// The person named the row.
    mutating func rowRenamed(to name: String) {
        pending = name
        awaiting = nil
        candidate = nil
    }

    /// The person sent the row back to its automatic name. The agent's own
    /// title is left alone, and what it says now is settled, so it is not
    /// taken back as the row's name.
    mutating func rowReset(sessionTitle: String?) {
        pending = nil
        awaiting = nil
        candidate = nil
        acknowledged = sessionTitle.flatMap { LaneRename.cleanName($0).isEmpty ? nil : LaneRename.cleanName($0) }
    }

    /// The rename was typed into the agent.
    mutating func typed(now: Date = Date()) {
        guard let name = pending else { return }
        awaiting = (name, now.addingTimeInterval(Self.awaitingWindow))
        pending = nil
    }

    /// The agent's title as just read. Returns the name the row should take,
    /// or nil when it should stay as it is.
    mutating func observe(title: String?, rowName: String?, now: Date = Date()) -> String? {
        if let waiting = awaiting, now >= waiting.until { awaiting = nil }
        let clean = title.map(LaneRename.cleanName).flatMap { $0.isEmpty ? nil : $0 }
        guard let clean else { candidate = nil; return nil }
        if let wanted = pending ?? awaiting?.name {
            if Self.same(clean, wanted) {
                if pending != nil { pending = nil }
                awaiting = nil
                acknowledged = clean
            }
            candidate = nil
            return nil
        }
        if Self.same(clean, acknowledged) { candidate = nil; return nil }
        if Self.same(clean, rowName) { acknowledged = clean; candidate = nil; return nil }
        guard Self.same(candidate, clean) else { candidate = clean; return nil }
        acknowledged = clean
        candidate = nil
        return clean
    }
}
