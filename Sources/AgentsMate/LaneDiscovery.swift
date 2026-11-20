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

    public init(kind: String, name: String, directory: String? = nil, attachedClients: Int? = nil, host: String? = nil) {
        self.kind = kind
        self.name = name
        self.directory = directory
        self.attachedClients = attachedClients
        self.host = host
    }

    /// The same for one session whichever backend reports it.
    public var key: String { [kind, host ?? "", name].joined(separator: "\u{1}") }
}

/// How a tmux lane wrapper names its sessions, so the backend can find the
/// lane sessions running with no row, attach one by name, and reach lanes
/// on another machine. Give it to ``CommandLaneBackend/tmuxSessions``.
///
/// A session counts as a lane session only when ``matches`` says so or its
/// name starts with one of ``prefixes``. With neither, nothing is listed:
/// a tmux server holds sessions of every kind, and only the app knows which
/// are its lanes.
public struct TmuxLaneSessions: Sendable {
    /// Lane session names start with one of these, such as `lane-`.
    public var prefixes: [String]
    /// Decides whether a session name is a lane's, in place of ``prefixes``.
    public var matches: (@Sendable (String) -> Bool)?
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
                sessionName: (@Sendable (AgentLane) -> String?)? = nil, host: String? = nil,
                tmux: String = "tmux", remoteTmux: String = "tmux", ssh: String = "/usr/bin/ssh",
                connectTimeout: Int = 5) {
        self.prefixes = prefixes
        self.matches = matches
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

    /// Whether a session is one of the app's lanes.
    public func isLaneSession(_ name: String) -> Bool {
        if let matches { return matches(name) }
        return prefixes.contains { !$0.isEmpty && name.hasPrefix($0) }
    }

    /// Whether anything can count as a lane session, so listing is worth a process.
    public var discovers: Bool { matches != nil || prefixes.contains { !$0.isEmpty } }

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
            guard isLaneSession(found.name) else { return nil }
            return DiscoveredSession(kind: Self.kind, name: found.name, directory: found.directory,
                                     attachedClients: found.attachedClients, host: host)
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
    /// matched to its status by name.
    static func lane(for found: Found) -> AgentLane {
        let session = found.session
        var lane = AgentLane(id: laneID(found), title: session.name,
                             directory: session.host == nil ? session.directory.map { URL(fileURLWithPath: $0, isDirectory: true) } : nil,
                             backendID: found.backendID, isClosable: false, statusMatch: .lane(session.name))
        lane.sessionName = session.name
        return lane
    }

    /// Whether a lane's row already attaches the session: by the name its
    /// backend knows it by, else the name its status is matched by, else
    /// (when the backend cannot name the lane) by folder.
    static func claims(_ lane: AgentLane, backend: any LaneBackend, _ session: DiscoveredSession) -> Bool {
        if let name = backend.sessionName(for: lane) { return name == session.name }
        if let name = (lane.statusMatch ?? backend.statusMatch(for: lane)).laneName { return name == session.name }
        guard let directory = session.directory else { return false }
        return LaneStatusMatch.normalizedPath(directory) == LaneStatusMatch.normalizedPath(lane.path)
    }

    /// The sessions no row attaches, one per session however many backends
    /// listed it; a row on any backend that listed a session claims it.
    static func unclaimed(_ found: [Found], lanes: [AgentLane], backends: [String: any LaneBackend]) -> [Found] {
        var reporters: [String: Set<String>] = [:]
        for item in found { reporters[item.session.key, default: []].insert(item.backendID) }
        var seen = Set<String>()
        var out: [Found] = []
        for item in found.sorted(by: { ($0.backendID, $0.session.name) < ($1.backendID, $1.session.name) }) {
            let key = item.session.key
            guard seen.insert(key).inserted else { continue }
            let ids = reporters[key] ?? []
            let claimed = lanes.contains { lane in
                guard ids.contains(lane.backendID), let backend = backends[lane.backendID] else { return false }
                return claims(lane, backend: backend, item.session)
            }
            if !claimed { out.append(item) }
        }
        return out
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
}
