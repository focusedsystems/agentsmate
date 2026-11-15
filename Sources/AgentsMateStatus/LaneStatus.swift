import Foundation

/// What an agent in a lane is doing, as its own hooks report it.
public enum LaneState: String, Codable, Sendable, CaseIterable {
    /// Working on a turn: a prompt was submitted or a tool just ran.
    case running
    /// Idle at its prompt, or asking a question, and waiting for a person.
    case waitingForInput
    /// Stopped on a permission prompt for a tool.
    case permissionRequested
    /// Finished its turn; the next prompt is the person's.
    case done
    /// The agent process ended. The lane itself may still be open.
    case ended

    /// Whether this state wants a person to look at the lane.
    public var wantsAttention: Bool {
        switch self {
        case .waitingForInput, .permissionRequested, .done: true
        case .running, .ended: false
        }
    }
}

/// One lane's latest status record, as written to the feed directory.
public struct LaneStatus: Codable, Equatable, Sendable {
    /// The agent that wrote it: `claude`, `codex`, or another backend's name.
    public var agent: String
    public var state: LaneState
    /// The tmux session the agent runs in, when it runs in one.
    public var lane: String?
    /// The agent's working directory.
    public var directory: String?
    /// The agent's own conversation or thread id.
    public var sessionID: String?
    /// A short human-readable note, such as the permission being asked for.
    public var message: String?
    /// The hook or notify event that produced this record.
    public var event: String
    public var updatedAt: Date
    /// The agent's conversation file, when its hooks name one.
    public var transcriptPath: String?

    public init(agent: String, state: LaneState, lane: String? = nil, directory: String? = nil,
                sessionID: String? = nil, message: String? = nil, event: String, updatedAt: Date = Date(),
                transcriptPath: String? = nil) {
        self.transcriptPath = transcriptPath
        self.agent = agent
        self.state = state
        self.lane = lane
        self.directory = directory
        self.sessionID = sessionID
        self.message = message
        self.event = event
        self.updatedAt = updatedAt
    }

    /// Whether this record came from polling a session list rather than from
    /// an event the agent sent. A poll is always fresh but knows less.
    public var isPolled: Bool { event == ClaudeAgentsList.event }

    /// The file name a record is stored under: one file per lane, or per
    /// conversation when the agent is not in a lane.
    public var key: String {
        let name = lane.flatMap { $0.isEmpty ? nil : $0 } ?? sessionID ?? directory ?? "unknown"
        return LaneStatus.slug(agent) + "--" + LaneStatus.slug(name)
    }

    static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let out = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return out.isEmpty ? "_" : String(out.prefix(120))
    }
}
