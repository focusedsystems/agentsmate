import Foundation
import AgentsMateStatus

/// Claude Code's own background sessions as lanes: `claude --bg -n <name>`
/// starts one, `claude attach <name>` draws it, and closing the terminal
/// leaves it running, the way detaching from tmux does.
///
/// Not a default anywhere: an app opts in by registering it. Its status
/// comes from ``ClaudeAgentsStatusSource`` rather than hooks alone. See
/// `docs/backends.md` for how it compares with tmux lanes.
public struct ClaudeBackgroundLaneBackend: LaneBackend {
    public var id: String
    public var displayName: String
    /// The `claude` command; a bare name is found on the login shell's PATH.
    public var claude: String
    /// Extra arguments for a new session, such as `--model`.
    public var startArguments: [String]
    /// The session name for a lane. It must be the same on every device so
    /// they all attach one session; the default is the folder's name.
    public var name: @Sendable (AgentLane) -> String
    /// List the background sessions running with no row, for the Detached
    /// section. Interactive sessions are never listed: they are not this
    /// backend's to attach.
    public var discoversSessions = true
    /// Which background sessions count as lanes, by name; nil counts every one.
    public var isLaneSession: (@Sendable (String) -> Bool)?
    /// Which background sessions count as lanes from their name and folder
    /// together, in place of ``isLaneSession``. A session's name is whatever
    /// started it chose, so the folder it works in is often the only sign of
    /// whose it is; ``DiscoveredSession/isInside(anyOf:)`` helps.
    public var isRelevant: (@Sendable (DiscoveredSession) -> Bool)?
    /// The `claude agents --json` list shared by every app on the Mac, read
    /// rather than run again while it is fresh.
    public var agentsListCache: URL = ClaudeBackgroundLaneBackend.defaultAgentsListCache

    public static var defaultAgentsListCache: URL {
        LaneStatusDirectory.default().url.deletingLastPathComponent().appendingPathComponent("claude-agents.json")
    }

    /// The `kind` of every session this lists.
    public static let kind = "claude-bg"

    public var keepsRunningWhenDetached: Bool { true }

    public init(id: String = "claude-bg", displayName: String = "Claude (background)", claude: String = "claude",
                startArguments: [String] = [], name: @escaping @Sendable (AgentLane) -> String = ClaudeBackgroundLaneBackend.folderName) {
        self.id = id
        self.displayName = displayName
        self.claude = claude
        self.startArguments = startArguments
        self.name = name
    }

    /// The folder's name in lower case, spaces and dots as dashes.
    @Sendable public static func folderName(_ lane: AgentLane) -> String {
        let base = (lane.path as NSString).lastPathComponent.lowercased()
        return base.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    public func launch(for lane: AgentLane, shell: String) -> TerminalLaunch {
        let claude = claude.isEmpty ? "claude" : claude
        // Several sessions can share a name, and `claude attach <name>` then
        // refuses, so a session whose id is known is attached by that id.
        if let id = attachID(for: lane) {
            let line = "exec \(claude) attach \(ShellQuote.quote(id))"
            return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: lane.path)
        }
        let session = ShellQuote.quote(sessionName(for: lane) ?? name(lane))
        let start = ([claude, "--bg", "-n", session] + startArguments.map(ShellQuote.quote)).joined(separator: " ")
        // Attach when the session exists; otherwise start it here, then attach.
        let line = "\(claude) attach \(session) 2>/dev/null || { \(start) >/dev/null && exec \(claude) attach \(session); }"
        return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: lane.path)
    }

    public func statusMatch(for lane: AgentLane) -> LaneStatusMatch {
        if let id = lane.agentSessionID, HostSessions.isValidAgentID(id) { return .session(id) }
        return .lane(sessionName(for: lane) ?? name(lane))
    }

    /// The short id to attach `lane` by: the one the row knows, else the
    /// one running session in the shared list with the lane's name and
    /// folder. Nil when neither is known, so the name is used and a new
    /// session started when none runs.
    func attachID(for lane: AgentLane) -> String? {
        if let id = lane.agentSessionID, HostSessions.isValidAgentID(id) { return id }
        guard let data = try? Data(contentsOf: agentsListCache) else { return nil }
        return Self.soleID(named: sessionName(for: lane) ?? name(lane), in: lane.path,
                           records: ClaudeAgentsList.parse(data))
    }

    /// The short id of the one live session in `records` named `name` and
    /// working in `folder`; nil when there is none or more than one.
    static func soleID(named name: String, in folder: String, records: [LaneStatus]) -> String? {
        let folder = LaneStatusMatch.normalizedPath(folder)
        let found = records.filter { record in
            record.state != .ended && record.lane == name
                && record.directory.map(LaneStatusMatch.normalizedPath) == folder
                && record.agentID.map(HostSessions.isValidAgentID) == true
        }
        return found.count == 1 ? found[0].agentID : nil
    }

    /// The session found by name, else the one ``name`` gives the lane.
    public func sessionName(for lane: AgentLane) -> String? {
        lane.sessionName ?? name(lane)
    }

    /// The background sessions in `claude agents --json` (interactive ones
    /// are left out), from the list every app shares, so this usually
    /// starts no process at all.
    public func discoverSessions() async -> [DiscoveredSession] {
        guard discoversSessions else { return [] }
        let binary: URL? = claude.contains("/") ? URL(fileURLWithPath: claude) : ClaudeBinary.locate()
        guard let binary else { return [] }
        let cache = agentsListCache, filter = isLaneSession, relevant = isRelevant
        let records = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                LaneRowMetadataReader.processSlots.wait()
                defer { LaneRowMetadataReader.processSlots.signal() }
                continuation.resume(returning: ClaudeAgentsList.shared(binary: binary, cache: cache))
            }
        }
        return Self.sessions(from: records, isLaneSession: filter, isRelevant: relevant)
    }

    static func sessions(from records: [LaneStatus], isLaneSession: (@Sendable (String) -> Bool)?,
                         isRelevant: (@Sendable (DiscoveredSession) -> Bool)? = nil) -> [DiscoveredSession] {
        // One per session: sessions can share a name, so they are told
        // apart by their short id, and by name only when they have none.
        var seen = Set<String>()
        return records.compactMap { record in
            guard let name = record.lane, !name.isEmpty else { return nil }
            let agentID = record.agentID.flatMap { HostSessions.isValidAgentID($0) ? $0 : nil }
            let session = DiscoveredSession(kind: kind, name: name, directory: record.directory, sessionID: record.sessionID,
                                            agentID: agentID)
            let counts = isRelevant.map { $0(session) } ?? isLaneSession?(name) ?? true
            guard counts, seen.insert(agentID.map { "id:" + $0 } ?? "name:" + name).inserted else { return nil }
            return session
        }
    }

    public var canStop: Bool { true }

    /// `claude stop` ends the session and keeps its conversation, by id
    /// when it is known, as attaching does.
    public func stop(_ lane: AgentLane) {
        LaneCommand.run([claude.isEmpty ? "claude" : claude, "stop", attachID(for: lane) ?? sessionName(for: lane) ?? name(lane)])
    }
}

/// Polls `claude agents --json` and hands its sessions to a ``LaneStatusFeed``.
public struct ClaudeAgentsStatusSource: LaneStatusSource {
    public let binary: URL
    /// Also report interactive sessions, such as Claude running in a tmux
    /// lane, so a lane shows its state before any hook has fired.
    public let includeInteractive: Bool

    /// The list shared by every app on the Mac; see ``ClaudeAgentsList/shared(cache:maxAge:includeInteractive:now:fetch:)``.
    public let cache: URL

    public init?(binary: URL? = ClaudeBinary.locate(), includeInteractive: Bool = false,
                 cache: URL = LaneStatusDirectory.default().url
                    .deletingLastPathComponent().appendingPathComponent("claude-agents.json")) {
        guard let binary else { return nil }
        self.binary = binary
        self.includeInteractive = includeInteractive
        self.cache = cache
    }

    public func records() async -> [LaneStatus] {
        let binary = binary, interactive = includeInteractive, cache = cache
        return await Task.detached(priority: .background) {
            ClaudeAgentsList.shared(binary: binary, cache: cache, includeInteractive: interactive)
        }.value
    }
}
