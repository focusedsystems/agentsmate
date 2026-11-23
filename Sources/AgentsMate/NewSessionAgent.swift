import Foundation
import AgentsMateStatus

/// An agent a new session can start on, whatever mode it runs in.
public enum LaneAgentKind: String, CaseIterable, Codable, Hashable, Sendable {
    case claude
    case codex
}

public extension LaneReopenChoice.Kind {
    /// The agents a new session can start on, each in a persistent session
    /// or run directly: every kind but ``sameAgent``.
    static let agentKinds: [LaneReopenChoice.Kind] = [.claudeRemote, .codexRemote, .claudeDirect, .codexDirect]

    /// `claude` or `codex`; nil for ``sameAgent``.
    var agent: String? {
        switch self {
        case .sameAgent: nil
        case .claudeRemote, .claudeDirect: "claude"
        case .codexRemote, .codexDirect: "codex"
        }
    }

    /// The agent, as ``LaneAgentKind``; nil for ``sameAgent``.
    var agentKind: LaneAgentKind? { agent.flatMap(LaneAgentKind.init(rawValue:)) }

    /// Whether the agent runs in a session that outlives the terminal.
    var isRemote: Bool { self == .claudeRemote || self == .codexRemote }

    /// The kind for `agent` (`claude`, `codex`) in a persistent session or
    /// run directly; nil for any other agent.
    init?(agent: String, remote: Bool) {
        switch agent.lowercased() {
        case "claude": self = remote ? .claudeRemote : .claudeDirect
        case "codex": self = remote ? .codexRemote : .codexDirect
        default: return nil
        }
    }

    /// The other agent, in the same mode.
    var otherAgent: LaneReopenChoice.Kind? {
        switch self {
        case .sameAgent: nil
        case .claudeRemote: .codexRemote
        case .codexRemote: .claudeRemote
        case .claudeDirect: .codexDirect
        case .codexDirect: .claudeDirect
        }
    }

    /// "Claude", "Codex".
    var agentName: String { agent.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Same Agent" }

    /// "Claude (remote)", "Codex (direct)".
    var title: String { self == .sameAgent ? agentName : "\(agentName) (\(isRemote ? "remote" : "direct"))" }
}

/// What a new session starts on, and why: the person's choice in Settings
/// or the app's default, moved to the other agent when the chosen one is
/// near its usage limit.
public struct NewSessionPlan: Equatable, Sendable {
    /// The backend the new session runs on.
    public var backendID: String
    /// The agent and mode that backend runs, when it is Claude or Codex.
    public var kind: LaneReopenChoice.Kind?
    /// The agent the session would have started on, when usage moved it.
    public var switchedFrom: LaneReopenChoice.Kind?
    /// Why it starts where it does, for a menu note or tooltip, such as
    /// "Claude at 93%, using Codex". Nil when nothing needs explaining.
    public var reason: String?

    public init(backendID: String, kind: LaneReopenChoice.Kind? = nil,
                switchedFrom: LaneReopenChoice.Kind? = nil, reason: String? = nil) {
        self.backendID = backendID
        self.kind = kind
        self.switchedFrom = switchedFrom
        self.reason = reason
    }
}

public extension AgentLaneStore {
    /// The usage switch's default threshold, in percent.
    static let defaultAgentSwitchThreshold = 90.0

    /// The person's choice of agent for new sessions on this Mac, saved
    /// under ``AgentsModeKeys/newSessionAgent``; nil follows the app's own
    /// default.
    var newSessionAgent: LaneReopenChoice.Kind? {
        get {
            defaults.string(forKey: keys.newSessionAgent).flatMap(LaneReopenChoice.Kind.init(rawValue:))
                .flatMap { $0 == .sameAgent ? nil : $0 }
        }
        set {
            if let newValue { defaults.set(newValue.rawValue, forKey: keys.newSessionAgent) }
            else { defaults.removeObject(forKey: keys.newSessionAgent) }
            objectWillChange.send()
        }
    }

    /// Whether a new session starts on the other agent when the chosen one
    /// is near its limit, saved under ``AgentsModeKeys/switchesAgentNearLimit``;
    /// on unless the person turns it off.
    var switchesAgentNearLimit: Bool {
        get { defaults.object(forKey: keys.switchesAgentNearLimit) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: keys.switchesAgentNearLimit)
            objectWillChange.send()
        }
    }

    /// The share of any usage limit, in percent, past which a new session
    /// starts on the other agent. Saved under
    /// ``AgentsModeKeys/agentSwitchThreshold``; 90 by default.
    var agentSwitchThreshold: Double {
        get {
            let value = (defaults.object(forKey: keys.agentSwitchThreshold) as? NSNumber)?.doubleValue
                ?? Self.defaultAgentSwitchThreshold
            return min(max(value, 1), 100)
        }
        set {
            defaults.set(min(max(newValue, 1), 100), forKey: keys.agentSwitchThreshold)
            objectWillChange.send()
        }
    }

    /// Which agent and mode a backend runs: the app's Reopen As choice for
    /// it, else a command backend's status agent, remote when its sessions
    /// outlive the terminal. Nil for a shell or any other program.
    func agentKind(ofBackend id: String) -> LaneReopenChoice.Kind? {
        if let choice = configuration.reopenChoices.first(where: { $0.backendID == id && $0.kind?.agent != nil }) {
            return choice.kind
        }
        guard let backend = backend(id: id) as? CommandLaneBackend,
              !backend.command.trimmingCharacters(in: .whitespaces).isEmpty,
              let agent = backend.statusAgent else { return nil }
        return LaneReopenChoice.Kind(agent: agent, remote: backend.keepsRunningWhenDetached)
    }

    /// The installed backend that runs `kind`: the app's Reopen As choice
    /// of that kind, else a backend that runs that agent in that mode.
    func backendID(forAgent kind: LaneReopenChoice.Kind) -> String? {
        func usable(_ id: String) -> Bool {
            guard let backend = backend(id: id) else { return false }
            return (backend as? CommandLaneBackend)?.isInstalled ?? true
        }
        if let choice = configuration.reopenChoices.first(where: { $0.kind == kind }), usable(choice.backendID) {
            return choice.backendID
        }
        return availableBackends.map(\.id)
            .filter { $0 != Self.customBackendID && usable($0) }
            .first { agentKind(ofBackend: $0) == kind }
    }

    /// The agent of the app's own default for a new session.
    var appDefaultAgent: LaneAgentKind? { agentKind(ofBackend: configuredNewLaneBackendID)?.agentKind }

    /// The agents the app lets the person or the switch pick at all.
    private var allowedAgentSet: Set<LaneAgentKind> { configuration.allowedAgents ?? Set(LaneAgentKind.allCases) }

    /// The agents a new session can start on here, in menu order: the app
    /// default's agent in either mode, and the other agent only when the
    /// app allows it and judges folders (``Configuration/agentAllowedForFolder``).
    var availableAgentKinds: [LaneReopenChoice.Kind] {
        let own = appDefaultAgent
        return LaneReopenChoice.Kind.agentKinds.filter { kind in
            guard let agent = kind.agentKind, allowedAgentSet.contains(agent) else { return false }
            guard agent == own || configuration.agentAllowedForFolder != nil else { return false }
            return backendID(forAgent: kind) != nil
        }
    }

    /// How full an agent's limits are, in percent, from the usage sources:
    /// its fullest window, or 100 when it is spent. Nil when unknown.
    func usagePercent(of agent: String, in usages: [AgentUsage]? = nil) -> Double? {
        let list = usages ?? usage?.usages ?? []
        guard let entry = list.first(where: { $0.agent.lowercased() == agent.lowercased() }) else { return nil }
        if entry.isDepleted { return 100 }
        return entry.fullest?.percent
    }

    /// Whether the person or the usage switch may start a session on
    /// `kind` in `folder`, where the app's default runs `appAgent`: the app
    /// allows the agent, and another agent than the default's only when the
    /// app judges folders and allows it in this one. Fails closed: no
    /// predicate, or no folder, keeps the default's agent.
    func mayPick(_ kind: LaneReopenChoice.Kind, in folder: URL?, appAgent: LaneAgentKind?) -> Bool {
        guard let agent = kind.agentKind, allowedAgentSet.contains(agent) else { return false }
        if agent == appAgent { return true }
        guard let allowed = configuration.agentAllowedForFolder, let folder else { return false }
        return allowed(agent, folder)
    }

    /// Whether the near-limit switch can ever move a session here: the app
    /// set ``Configuration/allowedAgents`` to both agents and gave
    /// ``Configuration/agentAllowedForFolder``.
    var canSwitchAgents: Bool {
        (configuration.allowedAgents?.count ?? 0) > 1 && configuration.agentAllowedForFolder != nil
    }

    /// What a new session in `folder` starts on. `preferred` is the app's
    /// default backend (else what Settings › Runs says, else the first
    /// installed one); the person's New Sessions choice wins over it when
    /// the app allows that agent there (``mayPick(_:in:appAgent:)``). When
    /// `switchingOnUsage` and the setting are on and that agent has used
    /// ``agentSwitchThreshold`` or more of any limit, the session starts on
    /// the other agent in the same mode, unless the app does not allow it
    /// there, it is as full, or it has no backend here. In doubt (unknown
    /// usage, a folder the app cannot judge) nothing moves. Sessions
    /// already open are never moved. `usages` stands in for the usage
    /// sources' figures.
    func newSessionPlan(preferring preferred: String? = nil, in folder: URL? = nil, switchingOnUsage: Bool = true,
                        usages: [AgentUsage]? = nil) -> NewSessionPlan {
        let fallback = preferred.flatMap { backend(id: $0) == nil ? nil : $0 } ?? configuredNewLaneBackendID
        var chosen: LaneReopenChoice.Kind?
        var backendID = fallback
        let appAgent = agentKind(ofBackend: fallback)?.agentKind
        if let wanted = newSessionAgent, mayPick(wanted, in: folder, appAgent: appAgent) {
            // A mode the app does not offer falls back to the same agent's other one.
            let candidates = [wanted, LaneReopenChoice.Kind(agent: wanted.agent ?? "", remote: !wanted.isRemote)]
            if let (kind, id) = candidates.compactMap({ kind in kind.flatMap { k in self.backendID(forAgent: k).map { (k, $0) } } }).first {
                chosen = kind
                backendID = id
            }
        }
        if chosen == nil { chosen = agentKind(ofBackend: backendID) }
        guard let kind = chosen else { return NewSessionPlan(backendID: backendID) }
        var plan = NewSessionPlan(backendID: backendID, kind: kind)
        guard switchingOnUsage, switchesAgentNearLimit, canSwitchAgents, let agent = kind.agent,
              let other = kind.otherAgent, mayPick(other, in: folder, appAgent: appAgent) else { return plan }
        if usages == nil { usage?.start() }
        let threshold = agentSwitchThreshold
        guard let used = usagePercent(of: agent, in: usages), used >= threshold else { return plan }
        let figure = "\(kind.agentName) at \(Int(used.rounded()))%"
        guard let otherID = self.backendID(forAgent: other) else {
            plan.reason = "\(figure), and \(other.title) isn’t available"
            return plan
        }
        if let otherUsed = usagePercent(of: other.agent ?? "", in: usages), otherUsed >= used {
            plan.reason = "\(figure), \(other.agentName) at \(Int(otherUsed.rounded()))%"
            return plan
        }
        return NewSessionPlan(backendID: otherID, kind: other, switchedFrom: kind,
                              reason: "\(figure), using \(other.agentName)")
    }
}
