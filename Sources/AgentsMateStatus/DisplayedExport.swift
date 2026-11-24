import Foundation

/// What an app's sidebar and All Agents board show right now, written by the
/// running app so other tools can check them without a screenshot.
///
/// The file is `<state home>/agentsmate/<bundle id>/displayed.json`
/// (``standardURL(bundleID:environment:)``), JSON, ``schemaVersion`` 1:
///
/// ```json
/// {"schema_version": 1,
///  "app": {"bundle_id": "com.example.app", "version": "1.2", "build": "34", "agentsmate_commit": null},
///  "written_at": "…Z", "last_discovery_finished_at": "…Z",
///  "filter": {"show": "active", "statuses": [], "search": null, "sidebar_search": null},
///  "counts": {"needs_you": 1, "working": 2, "idle_or_done": 3},
///  "rows": [{"section": "Heading", "title": "…", "lane_id": "…", "backend": "tmux", "agent": "claude",
///            "session_id": null, "attached_session_id": null, "session_name": "lane-a", "host": "host-a", "folder": "/path",
///            "state": "working", "attached": true, "selected": false, "is_parallel": false,
///            "is_top_level": true, "collapsed": false, "column": null}],
///  "all_agents": []}
/// ```
///
/// Only what the app shows is in it: a lane the app's scope hides, or that
/// the search and filters leave out, is not in `rows`.
public struct DisplayedExport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public struct App: Codable, Equatable, Sendable {
        public var bundleID: String
        public var version: String?
        public var build: String?
        /// The AgentsMate commit the app was built from, when it says.
        public var agentsMateCommit: String?

        public init(bundleID: String, version: String? = nil, build: String? = nil, agentsMateCommit: String? = nil) {
            self.bundleID = bundleID
            self.version = version
            self.build = build
            self.agentsMateCommit = agentsMateCommit
        }

        enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id", version, build, agentsMateCommit = "agentsmate_commit"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bundleID, forKey: .bundleID)
            try c.encode(version, forKey: .version)
            try c.encode(build, forKey: .build)
            try c.encode(agentsMateCommit, forKey: .agentsMateCommit)
        }
    }

    public struct Filter: Codable, Equatable, Sendable {
        /// `active` (only running sessions) or `all` (every lane).
        public var show: String
        /// The status chips that are on: `active`, `running`, `needs_you`, `idle`, `unread`.
        public var statuses: [String]
        /// All Agents' search text, when there is any.
        public var search: String?
        /// The sidebar's search text, when there is any.
        public var sidebarSearch: String?

        public init(show: String = "all", statuses: [String] = [], search: String? = nil, sidebarSearch: String? = nil) {
            self.show = show
            self.statuses = statuses
            self.search = search
            self.sidebarSearch = sidebarSearch
        }

        enum CodingKeys: String, CodingKey {
            case show, statuses, search, sidebarSearch = "sidebar_search"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(show, forKey: .show)
            try c.encode(statuses, forKey: .statuses)
            try c.encode(search, forKey: .search)
            try c.encode(sidebarSearch, forKey: .sidebarSearch)
        }
    }

    /// The header badges of All Agents, as they read.
    public struct Counts: Codable, Equatable, Sendable {
        public var needsYou: Int
        public var working: Int
        public var idleOrDone: Int

        public init(needsYou: Int = 0, working: Int = 0, idleOrDone: Int = 0) {
            self.needsYou = needsYou
            self.working = working
            self.idleOrDone = idleOrDone
        }

        enum CodingKeys: String, CodingKey {
            case needsYou = "needs_you", working, idleOrDone = "idle_or_done"
        }
    }

    /// A row's state, from the same mapping the UI uses.
    public enum State: String, Codable, Sendable, CaseIterable {
        case active, working
        case needsYou = "needs_you"
        case idle
        case notAttached = "not_attached"
        case stopped

        /// The states that say a session is running.
        public var claimsRunning: Bool { self == .active || self == .working || self == .needsYou }
    }

    public struct Row: Codable, Equatable, Sendable {
        /// The heading the row sits under; nil with no headings.
        public var section: String?
        public var title: String
        public var laneID: String
        /// `tmux`, `claude-bg`, `command`, `shell`, or the backend's own id.
        public var backend: String
        /// `claude`, `codex`, or nil.
        public var agent: String?
        /// The agent's id for the session (a background session's short id).
        public var sessionID: String?
        /// The id actually running in the row's pane, from its status record
        /// (a background session's short id, else the conversation id); nil
        /// when unknown. A value that differs from ``sessionID`` is a row
        /// attached to the wrong session.
        public var attachedSessionID: String?
        /// The tmux session name the row attaches.
        public var sessionName: String?
        public var host: String?
        public var folder: String?
        public var state: State
        public var attached: Bool
        public var selected: Bool
        public var isParallel: Bool
        public var isTopLevel: Bool
        /// The row's section is folded, so the sidebar draws no row for it now.
        public var collapsed: Bool
        /// All Agents only: `needs_you`, `working`, `idle_or_done` or `not_running`.
        public var column: String?

        public init(section: String? = nil, title: String, laneID: String, backend: String, agent: String? = nil,
                    sessionID: String? = nil, attachedSessionID: String? = nil, sessionName: String? = nil, host: String? = nil, folder: String? = nil,
                    state: State, attached: Bool = false, selected: Bool = false, isParallel: Bool = false,
                    isTopLevel: Bool = true, collapsed: Bool = false, column: String? = nil) {
            self.section = section
            self.title = title
            self.laneID = laneID
            self.backend = backend
            self.agent = agent
            self.sessionID = sessionID
            self.attachedSessionID = attachedSessionID
            self.sessionName = sessionName
            self.host = host
            self.folder = folder
            self.state = state
            self.attached = attached
            self.selected = selected
            self.isParallel = isParallel
            self.isTopLevel = isTopLevel
            self.collapsed = collapsed
            self.column = column
        }

        enum CodingKeys: String, CodingKey {
            case section, title, laneID = "lane_id", backend, agent, sessionID = "session_id",
                 attachedSessionID = "attached_session_id",
                 sessionName = "session_name", host, folder, state, attached, selected,
                 isParallel = "is_parallel", isTopLevel = "is_top_level", collapsed, column
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(section, forKey: .section)
            try c.encode(title, forKey: .title)
            try c.encode(laneID, forKey: .laneID)
            try c.encode(backend, forKey: .backend)
            try c.encode(agent, forKey: .agent)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(attachedSessionID, forKey: .attachedSessionID)
            try c.encode(sessionName, forKey: .sessionName)
            try c.encode(host, forKey: .host)
            try c.encode(folder, forKey: .folder)
            try c.encode(state, forKey: .state)
            try c.encode(attached, forKey: .attached)
            try c.encode(selected, forKey: .selected)
            try c.encode(isParallel, forKey: .isParallel)
            try c.encode(isTopLevel, forKey: .isTopLevel)
            try c.encode(collapsed, forKey: .collapsed)
            try c.encode(column, forKey: .column)
        }
    }

    public var schemaVersion: Int
    public var app: App
    /// Set when the file is written; not part of what ``sameContent(as:)`` compares.
    public var writtenAt: Date?
    public var lastDiscoveryFinishedAt: Date?
    public var filter: Filter
    public var counts: Counts
    /// The sidebar's rows, in sidebar order.
    public var rows: [Row]
    /// The cards All Agents shows, in board order.
    public var allAgents: [Row]

    public init(app: App, writtenAt: Date? = nil, lastDiscoveryFinishedAt: Date? = nil, filter: Filter = .init(),
                counts: Counts = .init(), rows: [Row] = [], allAgents: [Row] = []) {
        self.schemaVersion = Self.schemaVersion
        self.app = app
        self.writtenAt = writtenAt
        self.lastDiscoveryFinishedAt = lastDiscoveryFinishedAt
        self.filter = filter
        self.counts = counts
        self.rows = rows
        self.allAgents = allAgents
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", app, writtenAt = "written_at",
             lastDiscoveryFinishedAt = "last_discovery_finished_at", filter, counts, rows,
             allAgents = "all_agents"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(app, forKey: .app)
        try c.encode(writtenAt, forKey: .writtenAt)
        try c.encode(lastDiscoveryFinishedAt, forKey: .lastDiscoveryFinishedAt)
        try c.encode(filter, forKey: .filter)
        try c.encode(counts, forKey: .counts)
        try c.encode(rows, forKey: .rows)
        try c.encode(allAgents, forKey: .allAgents)
    }

    /// Whether `other` shows the same things, ignoring when it was written.
    public func sameContent(as other: DisplayedExport) -> Bool {
        var a = self, b = other
        a.writtenAt = nil
        b.writtenAt = nil
        return a == b
    }

    // MARK: Files

    /// `<state home>/agentsmate/<bundle id>/displayed.json`, the state home
    /// being `$XDG_STATE_HOME` when valid, else `~/.local/state`.
    public static func standardURL(bundleID: String,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        directory(bundleID: bundleID, environment: environment).appendingPathComponent("displayed.json", isDirectory: false)
    }

    /// The folder `displayed.json` goes in. A bundle id that is not a plain
    /// name (dots, dashes, letters, digits) is made one, so it cannot leave the folder.
    public static func directory(bundleID: String,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let safe = String(bundleID.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar) ? Character(scalar) : "_"
        })
        let name = safe.isEmpty || safe.hasPrefix(".") ? "_" + safe : safe
        return agentsMateStateDirectory(environment: environment).appendingPathComponent(name, isDirectory: true)
    }

    /// `<state home>/agentsmate`.
    public static func agentsMateStateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        LaneStatusDirectory.stateHome(environment: environment).appendingPathComponent("agentsmate", isDirectory: true)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    /// The file at `url`, or nil when it is missing, unreadable or of another schema.
    public static func load(_ url: URL) -> DisplayedExport? {
        guard let data = try? Data(contentsOf: url),
              let export = try? decoder.decode(DisplayedExport.self, from: data),
              export.schemaVersion == Self.schemaVersion else { return nil }
        return export
    }

    /// Write `data` to `url`: the folder is made private (mode 700), the
    /// bytes go to a private (mode 600) temporary file beside it, and a
    /// rename puts it in place, so a reader sees the old file or the new one,
    /// never half of one.
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var failed = false
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { failed = true; return }
                offset += n
            }
        }
        failed = (fsync(fd) != 0) || failed
        close(fd)
        guard !failed, rename(temporary.path, url.path) == 0 else {
            try? fm.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
