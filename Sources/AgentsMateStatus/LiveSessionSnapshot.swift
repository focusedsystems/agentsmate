import Foundation

/// What every host had running when it last looked, from a file an outside
/// watcher keeps. The app reads it at launch so active sessions show before
/// any host has been asked; what the hosts then say replaces it.
///
/// The file is JSON, schema 1:
///
/// ```json
/// {"schema": 1, "generated": "…Z", "hub": "hub-name",
///  "hosts": {"host-name": {"seen": "…Z", "sessions": [
///     {"id": "tmux:lane-a", "kind": "tmux", "name": "lane-a", "title": null,
///      "folder": "/path", "host": "host-name", "backend": "claude",
///      "state": "working", "lastActivity": "…Z", "attached": 1,
///      "lane": "app lane id or null", "sessionId": null, "agentId": null}]}}}
/// ```
///
/// `state` is one of `working`, `needs-you`, `idle`, `done` or `detached`.
/// Times are ISO 8601. A session or host that cannot be read is left out,
/// never the whole file; a file of another schema reads as nil.
public struct LiveSessionSnapshot: Equatable, Sendable {
    public enum State: String, Sendable, CaseIterable {
        case working
        case needsYou = "needs-you"
        case idle
        case done
        case detached
    }

    public struct Session: Equatable, Sendable, Identifiable {
        /// Unique on its host: `tmux:<name>`, `claude-bg:<short id>` and the like.
        public var id: String
        /// `tmux`, `background` or `interactive`.
        public var kind: String?
        /// The name the session is attached by: a tmux session's, a background session's.
        public var name: String
        /// What the agent calls the session, when it differs from ``name``.
        public var title: String?
        public var folder: String?
        public var host: String?
        /// `claude`, `codex` and the like.
        public var backend: String?
        public var state: State
        public var lastActivity: Date?
        /// Terminals attached to it, when known.
        public var attached: Int?
        /// The app lane the session belongs to, when the watcher knows it.
        public var lane: String?
        public var sessionID: String?
        /// The short id a background session is attached by.
        public var agentID: String?
        /// False when the watcher could not confirm the session this time
        /// and kept it from its last look.
        public var confirmed: Bool

        public init(id: String, kind: String? = nil, name: String, title: String? = nil, folder: String? = nil,
                    host: String? = nil, backend: String? = nil, state: State, lastActivity: Date? = nil,
                    attached: Int? = nil, lane: String? = nil, sessionID: String? = nil, agentID: String? = nil,
                    confirmed: Bool = true) {
            self.id = id
            self.kind = kind
            self.name = name
            self.title = title
            self.folder = folder
            self.host = host
            self.backend = backend
            self.state = state
            self.lastActivity = lastActivity
            self.attached = attached
            self.lane = lane
            self.sessionID = sessionID
            self.agentID = agentID
            self.confirmed = confirmed
        }
    }

    public struct Host: Equatable, Sendable {
        /// When the host last reported. Old, the host is stale: its sessions
        /// are what it had then, not what it has now.
        public var seen: Date?
        public var sessions: [Session]

        public init(seen: Date?, sessions: [Session]) {
            self.seen = seen
            self.sessions = sessions
        }
    }

    public static let schemaVersion = 1
    /// How long after its last report a host counts as stale.
    public static let staleAfter: TimeInterval = 10 * 60

    public var generated: Date?
    public var hub: String?
    public var hosts: [String: Host]

    public init(generated: Date? = nil, hub: String? = nil, hosts: [String: Host]) {
        self.generated = generated
        self.hub = hub
        self.hosts = hosts
    }

    /// `~/.local/state/agentsmate/live-sessions.json`, beside the apps' other shared state.
    public static var standardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/agentsmate/live-sessions.json", isDirectory: false)
    }

    /// Whether `host` has not reported within ``staleAfter`` of `now`, or never.
    public func isStale(_ host: String, now: Date = Date()) -> Bool {
        guard let seen = hosts[host]?.seen else { return true }
        return now.timeIntervalSince(seen) > Self.staleAfter
    }

    /// Every session on every host, hosts in name order.
    public var allSessions: [Session] {
        hosts.keys.sorted().flatMap { hosts[$0]?.sessions ?? [] }
    }

    // MARK: Reading

    /// The file at `url`, or nil, which means no snapshot: the file is
    /// missing, empty, unreadable, of another schema, bigger than
    /// ``maximumFileSize``, written more than ``maximumAge`` before `now`,
    /// or not private (owned by another user, or writable by group or
    /// others, so anyone else could have put sessions in it).
    public static func load(_ url: URL, now: Date = Date()) -> LiveSessionSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value, owner == getuid(),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value, mode & 0o022 == 0,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= maximumFileSize,
              let data = try? Data(contentsOf: url),
              let snapshot = decode(data) else { return nil }
        guard let generated = snapshot.generated, now.timeIntervalSince(generated) <= maximumAge else { return nil }
        return snapshot
    }

    public static let maximumFileSize = 4 << 20
    /// How old a whole file may be and still be read. The watcher rewrites it
    /// at least every few minutes while the Mac is awake; older, it says
    /// nothing about now.
    public static let maximumAge: TimeInterval = 30 * 60

    public static func decode(_ data: Data) -> LiveSessionSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema"] as? Int == schemaVersion else { return nil }
        var hosts: [String: Host] = [:]
        for (name, value) in root["hosts"] as? [String: Any] ?? [:] {
            guard Self.isPlainName(name), let host = value as? [String: Any] else { continue }
            let sessions = (host["sessions"] as? [Any] ?? []).compactMap { Self.session($0, host: name) }
            hosts[name] = Host(seen: date(host["seen"]), sessions: sessions)
        }
        return LiveSessionSnapshot(generated: date(root["generated"]),
                                   hub: (root["hub"] as? String).flatMap { isPlainName($0) ? $0 : nil },
                                   hosts: hosts)
    }

    private static func session(_ value: Any, host: String) -> Session? {
        guard let d = value as? [String: Any], let id = string(d["id"]),
              let state = (d["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        // A session is listed under the host it runs on; one that names
        // another host is not this host's to report.
        if let named = string(d["host"]), named != host { return nil }
        return Session(id: id, kind: string(d["kind"]), name: string(d["name"]) ?? id, title: string(d["title"]),
                       folder: string(d["folder"]), host: host, backend: string(d["backend"]), state: state,
                       lastActivity: date(d["lastActivity"]), attached: d["attached"] as? Int,
                       lane: string(d["lane"]), sessionID: string(d["sessionId"]), agentID: string(d["agentId"]),
                       confirmed: d["confirmed"] as? Bool ?? true)
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// A host name as the hosts registry writes one.
    static func isPlainName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 63, !name.hasPrefix("-"), !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }
}
