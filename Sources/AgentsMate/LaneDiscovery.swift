import Foundation
import AgentsMateStatus

/// A persistent session a backend found running, which may have no row yet.
///
/// A backend lists only its own lane sessions (see
/// ``LaneBackend/discoverSessions()``); the store adds each one no row
/// attaches to a Detached section.
public struct DiscoveredSession: Hashable, Sendable {
    /// What kind of session it is, such as `tmux` or `claude-bg`. Two
    /// backends that report the same kind, host and name found one session.
    public var kind: String
    /// The name the backend attaches it by: a tmux session's name, a
    /// background session's name.
    public var name: String
    /// The session's working folder, when the backend knows it.
    public var directory: String?
    /// Terminals attached to it anywhere, when the backend knows.
    public var attachedClients: Int?
    /// The machine it runs on; nil is this Mac.
    public var host: String?
    /// The agent's own id for the session, such as a Claude Code session
    /// id, when the backend knows it. A row that knows the same id holds
    /// the session whatever either is named.
    public var sessionID: String?
    /// The short id the backend attaches the session by, when it has one,
    /// such as a Claude Code background session's id. Names can repeat;
    /// this cannot, so a session with one is told apart by it.
    public var agentID: String?

    public init(kind: String, name: String, directory: String? = nil, attachedClients: Int? = nil, host: String? = nil,
                sessionID: String? = nil, agentID: String? = nil) {
        self.agentID = agentID
        self.kind = kind
        self.name = name
        self.directory = directory
        self.attachedClients = attachedClients
        self.host = host
        self.sessionID = sessionID
    }

    /// The same for one session whichever backend reports it: its short id
    /// when it has one, else its name.
    public var key: String { [kind, host ?? "", agentID ?? name].joined(separator: "\u{1}") }

    /// Whether the session's folder is one of `folders` or inside one, so an
    /// app can keep the sessions that work in its own folders. A session with
    /// no known folder is in none of them.
    public func isInside<Folders: Sequence>(anyOf folders: Folders) -> Bool where Folders.Element == String {
        guard let directory, !directory.isEmpty else { return false }
        let path = LaneStatusMatch.normalizedPath(directory)
        return folders.contains { folder in
            guard !folder.isEmpty else { return false }
            let root = LaneStatusMatch.normalizedPath(folder)
            return path == root || path.hasPrefix(root == "/" ? root : root + "/")
        }
    }
}

public extension DiscoveredSession {
    /// The folders under a repository that hold its worktrees.
    static let worktreeFolders = [".worktrees", ".claude/worktrees"]

    /// Whether the session works in one of `repositories` or in one of their
    /// worktrees, and not merely somewhere beneath them, so a folder that
    /// holds other projects does not claim every session started in them.
    func isInRepository<Folders: Sequence>(anyOf repositories: Folders) -> Bool where Folders.Element == String {
        Self.isInRepository(directory, anyOf: repositories)
    }

    /// ``isInRepository(anyOf:)`` for a folder, as saved lanes record it.
    static func isInRepository<Folders: Sequence>(_ directory: String?, anyOf repositories: Folders) -> Bool
    where Folders.Element == String {
        guard let directory, !directory.isEmpty else { return false }
        let path = LaneStatusMatch.normalizedPath(directory)
        return repositories.contains { folder in
            guard !folder.isEmpty else { return false }
            let root = LaneStatusMatch.normalizedPath(folder)
            if path == root { return true }
            let base = root == "/" ? "" : root
            return worktreeFolders.contains { name in
                let parent = base + "/" + name + "/"
                return path.hasPrefix(parent) && path.count > parent.count
            }
        }
    }
}

/// How a tmux lane wrapper names its sessions, so the backend can find the
/// lane sessions running with no row, attach one by name, and reach lanes
/// on another machine. Give it to ``CommandLaneBackend/tmuxSessions``.
///
/// A session counts as a lane session only when ``isRelevant`` accepts it,
/// else when ``matches`` says so, else when its name starts with one of
/// ``prefixes``. With none of them, nothing is listed: a tmux server holds
/// sessions of every kind, and only the app knows which are its lanes.
public struct TmuxLaneSessions: Sendable {
    /// Lane session names start with one of these, such as `lane-`.
    public var prefixes: [String]
    /// Decides whether a session name is a lane's, in place of ``prefixes``.
    public var matches: (@Sendable (String) -> Bool)?
    /// Decides whether a session is a lane's from its name and its folder
    /// together, in place of ``matches`` and ``prefixes``. For lanes whose
    /// names carry no mark of their own, so only the folder they work in
    /// says whose they are; ``DiscoveredSession/isInside(anyOf:)`` helps.
    public var isRelevant: (@Sendable (DiscoveredSession) -> Bool)?
    /// The tmux session a lane's wrapper attaches, when the app knows how
    /// it names them. Set, a row and a running session are matched by name
    /// rather than by folder, and a lane on ``host`` attaches it directly.
    public var sessionName: (@Sendable (AgentLane) -> String?)?
    /// An ssh destination whose tmux server holds the lanes, such as
    /// `user@build-mac`. Nil, the default, is this Mac. Not yet tested on
    /// real machines; see `docs/backends.md`.
    public var host: String?
    /// The local `tmux`: a path, or a name found in the usual install folders.
    public var tmux: String
    /// `tmux` on ``host``. An ssh command does not read the login shell's
    /// PATH there, so a full path may be needed.
    public var remoteTmux: String
    /// The local `ssh`.
    public var ssh: String
    /// Seconds ssh waits to connect.
    public var connectTimeout: Int

    public init(prefixes: [String] = [], matches: (@Sendable (String) -> Bool)? = nil,
                isRelevant: (@Sendable (DiscoveredSession) -> Bool)? = nil,
                sessionName: (@Sendable (AgentLane) -> String?)? = nil, host: String? = nil,
                tmux: String = "tmux", remoteTmux: String = "tmux", ssh: String = "/usr/bin/ssh",
                connectTimeout: Int = 5) {
        self.prefixes = prefixes
        self.matches = matches
        self.isRelevant = isRelevant
        self.sessionName = sessionName
        self.host = host
        self.tmux = TmuxLaneSessions.locate(tmux)
        self.remoteTmux = remoteTmux
        self.ssh = ssh
        self.connectTimeout = connectTimeout
    }

    /// The `kind` of every session this lists.
    public static let kind = "tmux"

    /// How long one listing may take: a local tmux answers at once, ssh
    /// has to connect first.
    static let localTimeout: TimeInterval = 5
    var listTimeout: TimeInterval { host == nil ? Self.localTimeout : TimeInterval(connectTimeout) + 10 }

    /// Whether a session name is one of the app's lanes, by ``matches`` or
    /// ``prefixes``. ``isRelevant``, when set, decides instead, with the
    /// whole session.
    public func isLaneSession(_ name: String) -> Bool {
        if let matches { return matches(name) }
        return prefixes.contains { !$0.isEmpty && name.hasPrefix($0) }
    }

    /// Whether a session is one of the app's lanes: ``isRelevant`` when set,
    /// else the name rule.
    public func isLaneSession(_ session: DiscoveredSession) -> Bool {
        if let isRelevant { return isRelevant(session) }
        return isLaneSession(session.name)
    }

    /// Whether anything can count as a lane session, so listing is worth a process.
    public var discovers: Bool { isRelevant != nil || matches != nil || prefixes.contains { !$0.isEmpty } }

    /// The host, when it is one ssh can be handed safely: no leading dash
    /// (which ssh would read as an option), no spaces or control characters,
    /// and only the characters a user, host name or address uses.
    public var validHost: String? {
        guard let host = host?.trimmingCharacters(in: .whitespaces), Self.isValidHost(host) else { return nil }
        return host
    }

    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-"), host.count <= 255 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:[]%")
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// A tmux session name that can be passed on: not empty, no control
    /// characters. Quoting takes care of everything else.
    public static func isValidSessionName(_ name: String) -> Bool {
        !name.isEmpty && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// `=name`: tmux matches the session name exactly rather than as a prefix.
    static func target(_ name: String) -> String { "=" + name }

    /// The command that attaches `session` with `tmux`, for a shell.
    static func attachCommand(tmux: String, session: String) -> String {
        ShellQuote.quote(tmux) + " attach-session -t " + ShellQuote.quote(target(session))
    }

    /// The shell line that attaches `session` on this Mac, or runs
    /// `fallback` (the wrapper) when that session has gone.
    public func localAttachLine(session: String, fallback: String?) -> String {
        let attach = Self.attachCommand(tmux: tmux, session: session)
        guard let fallback, !fallback.isEmpty else { return "exec " + attach }
        return attach + " 2>/dev/null || " + fallback
    }

    /// The shell line that runs `remote` on ``host`` in a terminal:
    /// `exec ssh -t -o ConnectTimeout=5 -- '<host>' '<remote>'`. The remote
    /// command is quoted once for the host's shell and again for this one.
    /// Nil when the host is not set or not valid.
    public func sshLine(remote: String) -> String? {
        guard let host = validHost else { return nil }
        return "exec " + ShellQuote.quote(ssh) + " -t -o " + ShellQuote.quote("ConnectTimeout=\(connectTimeout)")
            + " -- " + ShellQuote.quote(host) + " " + ShellQuote.quote(remote)
    }

    /// The shell line that attaches `session` on ``host``.
    public func remoteAttachLine(session: String) -> String? {
        guard Self.isValidSessionName(session) else { return nil }
        return sshLine(remote: Self.attachCommand(tmux: remoteTmux, session: session))
    }

    static let listFormat = "#{session_name}\t#{session_attached}\t#{pane_current_path}"

    /// What lists the sessions: `tmux list-sessions` here, or the same over
    /// ssh in batch mode (never prompting) when there is a host. Nil when
    /// the host is set but not valid.
    public func listCommand() -> (executable: String, arguments: [String])? {
        let list = ["list-sessions", "-F", Self.listFormat]
        guard host != nil else { return (tmux, list) }
        guard let host = validHost else { return nil }
        let remote = ([ShellQuote.quote(remoteTmux)] + list.map(ShellQuote.quote)).joined(separator: " ")
        return (ssh, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "--", host, remote])
    }

    /// What ends `session`: `tmux kill-session -t =name`, here or over ssh.
    public func stopCommand(session: String) -> [String]? {
        guard Self.isValidSessionName(session) else { return nil }
        let kill = ["kill-session", "-t", Self.target(session)]
        guard host != nil else { return [tmux] + kill }
        guard let host = validHost else { return nil }
        let remote = ([ShellQuote.quote(remoteTmux)] + kill.map(ShellQuote.quote)).joined(separator: " ")
        return [ssh, "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "--", host, remote]
    }

    /// The lane sessions in `list-sessions` output.
    public func sessions(fromListing output: String) -> [DiscoveredSession] {
        let host = validHost
        return TmuxPresenceSource.parse(output).compactMap { found in
            let session = DiscoveredSession(kind: Self.kind, name: found.name, directory: found.directory,
                                            attachedClients: found.attachedClients, host: host)
            return isLaneSession(session) ? session : nil
        }
    }

    /// List the lane sessions, at background priority, through the shared
    /// helper slots, with a timeout. Empty when nothing can count as a lane
    /// session, or when tmux or ssh fails.
    public func discover() async -> [DiscoveredSession] {
        guard discovers, let command = listCommand() else { return [] }
        let timeout = listTimeout
        // The helper blocks while it waits for a process slot, so it runs on
        // a dispatch queue rather than in Swift's concurrency pool.
        let output = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                continuation.resume(returning: LaneRowMetadataReader.run(command.executable, command.arguments, timeout: timeout))
            }
        }
        return sessions(fromListing: output)
    }

    static func locate(_ tmux: String) -> String {
        if tmux.contains("/") { return tmux }
        return ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { $0 + "/" + tmux }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? tmux
    }
}

/// Matching what the backends found against the rows, for the Detached section.
enum DetachedSessions {
    /// A Claude background session a row owns by the bindings: the host it
    /// runs on (nil for this Mac) and its exact short id.
    struct OwnedSession: Hashable, Sendable {
        var host: String?
        var agentID: String
    }

    struct Found: Equatable, Sendable {
        var backendID: String
        var session: DiscoveredSession
    }

    /// The id a detached row gets, the same at every launch so its
    /// selection and any name the person gives it stay.
    static func laneID(_ found: Found) -> String {
        "agentsmate.detached:" + found.backendID + ":" + found.session.key
    }

    /// The row for a session nothing attaches: not started, not closable,
    /// matched to its status by its id when it has one, else by name. A
    /// session with a short id is attached by that id, and when another
    /// listed session shares its name (`sharesName`) the title carries the
    /// id too, so the rows can be told apart.
    static func lane(for found: Found, sharesName: Bool = false) -> AgentLane {
        let session = found.session
        let id = session.agentID
        let match: LaneStatusMatch = id.map { .session(session.sessionID ?? $0) } ?? .lane(session.name)
        var lane = AgentLane(id: laneID(found), title: title(for: session, sharesName: sharesName),
                             directory: session.host == nil ? session.directory.map { URL(fileURLWithPath: $0, isDirectory: true) } : nil,
                             backendID: found.backendID, isClosable: false, statusMatch: match)
        lane.sessionName = session.name
        lane.agentSessionID = id
        return lane
    }

    /// A detached row's title: the session's name, with its short id after
    /// it when another session shares the name.
    static func title(for session: DiscoveredSession, sharesName: Bool) -> String {
        guard sharesName, let id = session.agentID else { return session.name }
        return session.name + " · " + id
    }

    /// The names more than one of `found` share on one backend and machine.
    static func sharedNames(_ found: [Found]) -> Set<String> {
        var counts: [String: Int] = [:]
        for item in found {
            counts[[item.backendID, item.session.kind, item.session.host ?? "", item.session.name].joined(separator: "\u{1}"), default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    static func sharesName(_ item: Found, in shared: Set<String>) -> Bool {
        shared.contains([item.backendID, item.session.kind, item.session.host ?? "", item.session.name].joined(separator: "\u{1}"))
    }

    /// Whether a row that knows its session's short id holds `session`: the
    /// same id. Nil when either id is unknown, so the name decides.
    static func sameAgent(_ lane: AgentLane, _ session: DiscoveredSession) -> Bool? {
        guard let held = lane.agentSessionID, !held.isEmpty, let id = session.agentID else { return nil }
        return sameSession(held, id)
    }

    /// Whether a lane's row already attaches the session: by the name its
    /// backend knows it by, else the name its status is matched by, else
    /// (when the backend cannot name the lane) by folder.
    static func claims(_ lane: AgentLane, backend: any LaneBackend, _ session: DiscoveredSession) -> Bool {
        if let same = sameAgent(lane, session) { return same }
        if let name = laneName(lane, backend: backend) { return name == session.name }
        guard let directory = session.directory else { return false }
        return LaneStatusMatch.normalizedPath(directory) == LaneStatusMatch.normalizedPath(lane.path)
    }

    /// The session name a row attaches, when its backend or status match
    /// gives one.
    static func laneName(_ lane: AgentLane, backend: any LaneBackend) -> String? {
        backend.sessionName(for: lane) ?? (lane.statusMatch ?? backend.statusMatch(for: lane)).laneName
    }

    /// The machine a backend's lanes run on; nil is this Mac.
    static func laneHost(_ backend: any LaneBackend) -> String? {
        (backend as? CommandLaneBackend)?.tmuxSessions?.validHost
    }

    /// The sessions no row attaches, one per session however many backends
    /// listed it. A row holds a session when:
    ///
    /// - it knows the session's own id, from `heldSessionIDs` (the id its
    ///   status is matched by, or the one its status record carries), on
    ///   any backend;
    /// - it is on a backend that listed the session and claims it by name or
    ///   folder (``claims(_:backend:_:)``);
    /// - it is on another backend on the same machine and its session name
    ///   is the session's, as a wrapper's row is that attaches a tmux lane
    ///   or a Claude Code background session of the same name;
    /// - or, knowing no session id, it runs Claude in a folder where exactly
    ///   one Claude Code background session works, which a wrapper attaches
    ///   whatever it named the session.
    ///
    /// Before any of these, a Claude background session a row owns by the
    /// bindings (`ownedSessionIDs`) is that row's whatever its name: on the
    /// same host, with exactly the bound short id, never a prefix. It is
    /// not also listed apart, while the other sessions in the row's folder
    /// still are. A row that owns a session takes no other by folder.
    ///
    /// Folders alone are not enough across backends otherwise: a Codex lane
    /// and a Claude lane share a folder.
    static func unclaimed(_ found: [Found], lanes: [AgentLane], backends: [String: any LaneBackend],
                          heldSessionIDs: [AgentLane.ID: [String]] = [:],
                          ownedSessionIDs: [AgentLane.ID: OwnedSession] = [:]) -> [Found] {
        let rowIDs = Set(lanes.map(\.id))
        let owned = Set(ownedSessionIDs.filter { rowIDs.contains($0.key) && !$0.value.agentID.isEmpty }.values)
        var reporters: [String: Set<String>] = [:]
        var backgroundPerFolder: [String: Int] = [:]
        var counted = Set<String>()
        for item in found {
            reporters[item.session.key, default: []].insert(item.backendID)
            if item.session.kind == ClaudeBackgroundLaneBackend.kind, item.session.host == nil,
               let directory = item.session.directory, counted.insert(item.session.key).inserted {
                backgroundPerFolder[LaneStatusMatch.normalizedPath(directory), default: 0] += 1
            }
        }
        // Rows that run Claude and know no session id, by folder, for the
        // one-session-in-the-folder rule.
        var claudeFolders = Set<String>()
        for lane in lanes where (heldSessionIDs[lane.id] ?? []).isEmpty && ownedSessionIDs[lane.id] == nil {
            guard let backend = backends[lane.backendID], laneHost(backend) == nil, runsClaude(backend) else { continue }
            claudeFolders.insert(LaneStatusMatch.normalizedPath(lane.path))
        }
        let heldIDs = heldSessionIDs.values.flatMap { $0 }.filter { !$0.isEmpty }
        var seen = Set<String>()
        var out: [Found] = []
        for item in found.sorted(by: { ($0.backendID, $0.session.name) < ($1.backendID, $1.session.name) }) {
            let key = item.session.key
            guard seen.insert(key).inserted else { continue }
            let session = item.session
            if session.kind == ClaudeBackgroundLaneBackend.kind, let id = session.agentID,
               owned.contains(OwnedSession(host: session.host, agentID: id)) { continue }
            if let id = session.sessionID, heldIDs.contains(where: { sameSession(id, $0) }) { continue }
            if session.kind == ClaudeBackgroundLaneBackend.kind, session.host == nil, let directory = session.directory {
                let folder = LaneStatusMatch.normalizedPath(directory)
                if backgroundPerFolder[folder] == 1, claudeFolders.contains(folder) { continue }
            }
            let ids = reporters[key] ?? []
            let claimed = lanes.contains { lane in
                guard let backend = backends[lane.backendID] else { return false }
                if ids.contains(lane.backendID) { return claims(lane, backend: backend, session) }
                guard laneHost(backend) == session.host else { return false }
                if let same = sameAgent(lane, session) { return same }
                return laneName(lane, backend: backend) == session.name
            }
            if !claimed { out.append(item) }
        }
        return out
    }

    /// The row a session no row attaches belongs beside: a row on the same
    /// machine whose folder is the session's or holds it (a worktree, or any
    /// folder inside), so the session shows under that row's section rather
    /// than apart from it. The deepest folder wins; on a tie, a row the app
    /// gave (not closable) before one the person opened, then the first in
    /// `lanes`. A row with no folder of its own, or one at the home folder
    /// or the root, holds nothing: it would claim every session. Nil when no
    /// row's folder holds the session.
    ///
    /// `normalize` turns a path into the form compared, as
    /// ``LaneStatusMatch/normalizedPath(_:)`` does.
    static func owner(of session: DiscoveredSession, among lanes: [AgentLane], backends: [String: any LaneBackend],
                      normalize: (String) -> String = LaneStatusMatch.normalizedPath) -> AgentLane.ID? {
        guard let directory = session.directory, !directory.isEmpty else { return nil }
        let path = normalize(directory)
        let tooBroad: Set<String> = ["/", normalize(FileManager.default.homeDirectoryForCurrentUser.path)]
        var best: (lane: AgentLane, depth: Int)?
        for lane in lanes {
            guard let folder = lane.directory, let backend = backends[lane.backendID],
                  laneHost(backend) == session.host else { continue }
            let root = normalize(folder.path)
            guard !tooBroad.contains(root), path == root || path.hasPrefix(root + "/") else { continue }
            let depth = root.count
            if let current = best {
                if depth < current.depth { continue }
                if depth == current.depth, !(current.lane.isClosable && !lane.isClosable) { continue }
            }
            best = (lane, depth)
        }
        return best?.lane.id
    }

    /// Two ids for one session: the same, or one the start of the other, as
    /// a lane wrapper may record only the first eight characters.
    static func sameSession(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Whether a backend's lanes run Claude Code.
    static func runsClaude(_ backend: any LaneBackend) -> Bool {
        if backend is ClaudeBackgroundLaneBackend { return true }
        return (backend as? CommandLaneBackend)?.statusAgent == "claude"
    }

    /// The agent session ids a row holds: the one its status is matched by
    /// and the one its current status record carries.
    static func heldSessionIDs(match: LaneStatusMatch, record: LaneStatus?) -> [String] {
        var ids = match.sessionIDs
        if let id = record?.sessionID, !id.isEmpty, !ids.contains(id) { ids.append(id) }
        return ids
    }
}

extension LaneStatusMatch {
    /// The session name a match looks for, if it looks for one.
    var laneName: String? {
        switch self {
        case .lane(let name): return name
        case .firstOf(let matches): return matches.lazy.compactMap(\.laneName).first
        default: return nil
        }
    }

    /// The agent session ids a match looks for.
    var sessionIDs: [String] {
        switch self {
        case .session(let id): return id.isEmpty ? [] : [id]
        case .firstOf(let matches): return matches.flatMap(\.sessionIDs)
        default: return []
        }
    }
}
