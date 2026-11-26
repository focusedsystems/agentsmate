import Foundation
import AgentsMateStatus

/// Claude Code's own background sessions as lanes: `claude --bg -n <name>`
/// starts one, `claude attach <id>` draws it, and closing the terminal
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
    /// Once a row is attached (`claude attach` running in its pane) it is
    /// Claude Code's own input line, so `/rename` is typed there like any
    /// other lane's, and only while the pane is attached and idle.
    public var renameCommand: String? = LaneRename.slashRename
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

    /// Where a lane's start line writes the short id `claude --bg` printed,
    /// one file per lane id, for the store to bind to the row.
    public var startedIDDirectory: URL = ClaudeBackgroundLaneBackend.defaultStartedIDDirectory

    /// Names that mean this Mac, compared ignoring case. A lane whose host is
    /// one of them runs here, the same as a lane with no host. That includes
    /// the name the hosts registry gives this Mac, which is the name lanes carry.
    public var localHostNames: Set<String> = AgentHosts.thisMacNames.union(AgentHosts.load().map { [$0.selfName] } ?? [])

    /// Whether `host` is another machine: set, and not one of this Mac's names.
    func isRemote(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let names = Set(localHostNames.map { $0.lowercased() })
        return !names.contains(host.lowercased())
    }

    /// Which row holds which short id, kept by the store, so a name never
    /// resolves to a session another row already has.
    public var holders = SessionHolders()

    public static var defaultStartedIDDirectory: URL {
        LaneStatusDirectory.default().url.deletingLastPathComponent().appendingPathComponent("claude-bg-started")
    }

    /// The file a lane's start line writes its new session's id to.
    public func startedIDFile(for lane: AgentLane) -> URL {
        let safe = String(lane.id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return startedIDDirectory.appendingPathComponent(safe)
    }

    /// The id a lane's start line recorded, when it is a valid short id.
    public func startedID(for lane: AgentLane) -> String? {
        guard let raw = try? String(contentsOf: startedIDFile(for: lane), encoding: .utf8) else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return HostSessions.isValidAgentID(id) ? id : nil
    }

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
        let name = sessionName(for: lane) ?? name(lane)
        let line: String
        // `claude attach <name>` also takes part of a name and refuses when
        // several sessions match, so a session is only ever attached by id.
        switch resolution(for: lane) {
        case .one(let id):
            // A session the person stopped is never woken by selecting its
            // row: attaching a stopped id would start it again.
            if lane.agentSessionID == id, liveness(of: id) == .stopped {
                line = Self.stoppedLine(name: name, id: id)
            } else {
                line = "exec \(claude) attach \(ShellQuote.quote(id))"
            }
        case .several(let ids):
            line = Self.ambiguousLine(name: name, ids: ids)
        case .held:
            let message = "Another row already has the session named “\(name)” open, so it was not attached here."
            line = "printf '%s\\n' \(ShellQuote.quote(message)); exit 1"
        case .none:
            line = Self.startLine(claude: claude, name: name, arguments: startArguments,
                                  recordingTo: startedIDFile(for: lane).path)
        case .elsewhere(let host):
            let message = "“\(name)” runs on \(host), and its session id is not known here, so nothing was attached."
            line = "printf '%s\\n' \(ShellQuote.quote(message)); exit 1"
        }
        return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: lane.path)
    }

    /// Start a new background session named `name` in the lane's folder,
    /// read the short id `claude --bg` prints, and attach that id.
    static func startLine(claude: String, name: String, arguments: [String], recordingTo file: String? = nil) -> String {
        let start = ([claude, "--bg", "-n", ShellQuote.quote(name)] + arguments.map(ShellQuote.quote)).joined(separator: " ")
        // `backgrounded · <id> · <name>`, then `claude attach <id>` among the hints.
        let parse = "sed -n -e 's/^backgrounded [^ ]* \\([A-Za-z0-9][A-Za-z0-9-]*\\) .*/\\1/p'"
            + " -e 's/^ *claude attach \\([A-Za-z0-9][A-Za-z0-9-]*\\).*/\\1/p' | head -n 1"
        let failed = ShellQuote.quote("Claude started the session but did not print its id, so it was not attached.")
        let record = file.map { path in
            let dir = ShellQuote.quote((path as NSString).deletingLastPathComponent)
            return "mkdir -p \(dir) 2>/dev/null; printf '%s\\n' \"$id\" > \(ShellQuote.quote(path)) 2>/dev/null; "
        } ?? ""
        return "out=$(\(start)) || exit; id=$(printf '%s\\n' \"$out\" | \(parse)); "
            + "[ -n \"$id\" ] || { printf '%s\\n' \(failed) \"$out\"; exit 1; }; \(record)exec \(claude) attach \"$id\""
    }

    /// Whether the shared list shows a session.
    public enum Liveness: Equatable, Sendable {
        case live, stopped
        /// The list cannot be read, so nothing is known.
        case unknown
    }

    /// Whether the daemon's list (the cache every app shares) shows `id`.
    /// A session missing from a list that was read is stopped.
    public func liveness(of id: String) -> Liveness {
        guard let data = try? Data(contentsOf: agentsListCache), !data.isEmpty,
              (try? JSONSerialization.jsonObject(with: data)) is [Any] else { return .unknown }
        let records = ClaudeAgentsList.parse(data, includeInteractive: false)
        return records.contains { $0.agentID == id && $0.state != .ended } ? .live : .stopped
    }

    /// The full session id of the conversation behind a row's short id: the
    /// one the row recorded, else the one the list shows for that short id.
    /// Nil when neither is known. Never found by name or folder.
    public func conversationID(for lane: AgentLane) -> String? {
        if let held = lane.agentConversationID, Self.isValidConversationID(held) { return held }
        guard let id = lane.agentSessionID, let data = try? Data(contentsOf: agentsListCache) else { return nil }
        return ClaudeAgentsList.parse(data, includeInteractive: false)
            .first { $0.agentID == id && $0.sessionID.map(Self.isValidConversationID) == true }?.sessionID
    }

    static func isValidConversationID(_ id: String) -> Bool {
        id.count >= 16 && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "-") }
    }

    /// The pane for a row whose session is stopped: a message, nothing run.
    static func stoppedLine(name: String, id: String) -> String {
        let message = "“\(name)” (\(id)) is stopped, so it was not attached. Choose Resume to continue its conversation here."
        return "printf '%s\\n' \(ShellQuote.quote(message)); exit 1"
    }

    /// Continue the row's own conversation in its own pane with
    /// `claude --resume <full session id>`; with `stoppingBackground`, after
    /// `claude stop <id>` has finished. Never a new session: when the row has
    /// no id or its full session id is unknown, the pane says so instead.
    public func resumeLaunch(for lane: AgentLane, shell: String, stoppingBackground: Bool) -> TerminalLaunch {
        let claude = claude.isEmpty ? "claude" : claude
        let name = sessionName(for: lane) ?? name(lane)
        let line: String
        if isRemote(lane.host) {
            line = Self.refusal("“\(name)” runs on another host, so it cannot be resumed here.")
        } else if let id = lane.agentSessionID, HostSessions.isValidAgentID(id) {
            if let full = conversationID(for: lane) {
                let stop = stoppingBackground ? "\(claude) stop \(ShellQuote.quote(id)); " : ""
                line = stop + "exec \(claude) --resume \(ShellQuote.quote(full))"
            } else {
                line = Self.refusal("The conversation id of “\(name)” is not known, so it was not resumed.")
            }
        } else {
            line = Self.refusal("“\(name)” has no session id, so it was not resumed.")
        }
        return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: lane.path)
    }

    static func refusal(_ message: String) -> String {
        "printf '%s\\n' \(ShellQuote.quote(message)); exit 1"
    }

    /// A message in the pane when several running sessions have the lane's
    /// name in its folder, rather than attaching one of them at random.
    static func ambiguousLine(name: String, ids: [String]) -> String {
        let message = "\(ids.count) background sessions named “\(name)” run in this folder: \(ids.joined(separator: ", ")). "
            + "Open the one you want from the Detached section, or stop the others, then choose Reattach."
        return "printf '%s\\n' \(ShellQuote.quote(message)); exit 1"
    }

    public func statusMatch(for lane: AgentLane) -> LaneStatusMatch {
        if let id = lane.agentSessionID, HostSessions.isValidAgentID(id) {
            // Only this row's own sessions: its short id, or the conversation
            // it was resumed as. Another session in its folder or tagged with
            // its lane id never colours it.
            if let full = lane.agentConversationID, Self.isValidConversationID(full) {
                return .firstOf([.session(id), .session(full)])
            }
            return .session(id)
        }
        return .lane(sessionName(for: lane) ?? name(lane))
    }

    /// Which running session a lane attaches.
    enum Resolution: Equatable {
        /// Attach this short id.
        case one(String)
        /// Several sessions fit; attach none of them.
        case several([String])
        /// None runs: start one.
        case none
        /// The lane is on another host, which this Mac's list cannot speak for.
        case elsewhere(String)
        /// The one session with the name is another row's.
        case held(String)
    }

    /// The session `lane` attaches: the id the row knows, else the running
    /// session in the shared list with the lane's name and folder.
    func resolution(for lane: AgentLane) -> Resolution {
        if let id = lane.agentSessionID, HostSessions.isValidAgentID(id) { return .one(id) }
        if let id = startedID(for: lane) { return .one(id) }
        // This Mac's list says nothing about another host's sessions.
        if let host = lane.host, isRemote(host) { return .elsewhere(host) }
        // A row that must start its own session never takes one by name.
        if lane.startsNewSession { return .none }
        guard let data = try? Data(contentsOf: agentsListCache) else { return .none }
        let found = Self.resolve(name: sessionName(for: lane) ?? name(lane), in: lane.path,
                                 records: ClaudeAgentsList.parse(data, includeInteractive: false))
        if case .one(let id) = found, let holder = holders.holder(of: id), holder != lane.id { return .held(id) }
        return found
    }

    /// The short id to attach `lane` by, when exactly one is known.
    func attachID(for lane: AgentLane) -> String? {
        if case .one(let id) = resolution(for: lane) { return id }
        return nil
    }

    /// The live sessions in `records` (one host's list) working in `folder`
    /// whose name is `name`, ignoring case. Only one is attached: with two
    /// or more, none is. Never part of a name.
    static func resolve(name: String, in folder: String, records: [LaneStatus]) -> Resolution {
        let folder = LaneStatusMatch.normalizedPath(folder)
        let found = records.filter { record in
            // Only background sessions: an interactive one is never bound.
            record.event == ClaudeAgentsList.event && record.message == ClaudeAgentsList.backgroundMessage
                && record.state != .ended && record.directory.map(LaneStatusMatch.normalizedPath) == folder
                && record.agentID.map(HostSessions.isValidAgentID) == true
                && record.lane?.caseInsensitiveCompare(name) == .orderedSame
        }
        let ids = Array(Set(found.compactMap(\.agentID))).sorted()
        switch ids.count {
        case 0: return .none
        case 1: return .one(ids[0])
        default: return .several(ids)
        }
    }

    /// The short id of the one live session in `records` named `name` and
    /// working in `folder`; nil when there is none or more than one.
    static func soleID(named name: String, in folder: String, records: [LaneStatus]) -> String? {
        if case .one(let id) = resolve(name: name, in: folder, records: records) { return id }
        return nil
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
            // Not in the row metadata's queue: every row's git reads wait
            // there, and the list of sessions is what the window waits on.
            // The shared list's own lock keeps this to one process.
            DispatchQueue.global(qos: .utility).async {
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

    /// Only a lane bound to one session by its id can be stopped; without
    /// the id `claude stop` has nothing to name.
    public func canStop(_ lane: AgentLane) -> Bool { attachID(for: lane) != nil }

    /// `claude stop` ends the session and keeps its conversation. Only by
    /// id: a name can match several sessions, or part of another's name.
    public func stop(_ lane: AgentLane) {
        guard let id = attachID(for: lane) else { return }
        LaneCommand.run([claude.isEmpty ? "claude" : claude, "stop", id])
        forgetInList(id)
    }

    /// Take a stopped session out of the shared list at once, so a row does
    /// not read it as live until the list is next fetched.
    func forgetInList(_ id: String) {
        guard let data = try? Data(contentsOf: agentsListCache),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let kept = entries.filter { ($0["id"] as? String) != id }
        guard kept.count != entries.count, let out = try? JSONSerialization.data(withJSONObject: kept) else { return }
        try? out.write(to: agentsListCache, options: .atomic)
    }
}

/// Which row holds which Claude short id, shared by every copy of a backend.
public final class SessionHolders: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: String] = [:]

    public init() {}

    /// Replace the record: lane id by short id.
    public func set(_ holders: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        byID = holders
    }

    /// The lane id of the row holding `id`, if any.
    public func holder(of id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return byID[id]
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
