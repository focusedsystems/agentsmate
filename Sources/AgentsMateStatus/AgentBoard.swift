import Foundation

/// Every agent session on every Mac, gathered from what each app on each
/// Mac exports (``DisplayedExport``), for a board that is not itself an
/// agent app.
///
/// Each Mac is read the same way, by one read-only `sh` script
/// (``AgentBoard/script(marks:)``): run here directly, or over `ssh` in
/// batch mode for another Mac. Its output carries every app's export, every
/// app's summaries, the Mac's Claude Code background sessions and the bundle
/// ids of the apps running there. ``AgentBoard/cards(from:localHost:)``
/// turns those snapshots into one card per session.
public enum AgentBoard {
    /// Which column a card sits in.
    public enum Column: String, Sendable, CaseIterable, Identifiable {
        case needsYou = "needs_you"
        case working
        case idleOrDone = "idle_or_done"
        case notRunning = "not_running"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .needsYou: "Needs You"
            case .working: "Working"
            case .idleOrDone: "Idle & Done"
            case .notRunning: "Not Running"
            }
        }

        /// The more urgent column first: what a duplicate of a card keeps.
        var urgency: Int {
            switch self {
            case .needsYou: 0
            case .working: 1
            case .idleOrDone: 2
            case .notRunning: 3
            }
        }

        static func of(row: DisplayedExport.Row) -> Column {
            if let column = row.column, let known = Column(rawValue: column) { return known }
            switch row.state {
            case .needsYou: return .needsYou
            case .working: return .working
            case .active, .idle: return .idleOrDone
            case .notAttached, .stopped, .unknown: return .notRunning
            }
        }

        static func of(state: LaneState) -> Column {
            switch state {
            case .waitingForInput, .permissionRequested: .needsYou
            case .running: .working
            case .done: .idleOrDone
            case .ended: .notRunning
            }
        }
    }

    /// One summary an app wrote for a session's conversation.
    public struct Summary: Equatable, Sendable {
        public var text: String
        public var generatedAt: Date?
        /// The conversation id, from the transcript file's name.
        public var conversationID: String
    }

    /// What one Mac had when it was asked.
    public struct HostSnapshot: Equatable, Sendable {
        /// The Mac's name in the hosts registry.
        public var host: String
        public var exports: [DisplayedExport]
        /// Conversation id to the newest summary any app on the Mac wrote.
        public var summaries: [String: Summary]
        /// Claude Code's background sessions on the Mac.
        public var claudeSessions: [LaneStatus]
        /// Bundle ids of the apps running on the Mac; nil when not known.
        public var runningApps: Set<String>?

        public init(host: String, exports: [DisplayedExport] = [], summaries: [String: Summary] = [:],
                    claudeSessions: [LaneStatus] = [], runningApps: Set<String>? = nil) {
            self.host = host
            self.exports = exports
            self.summaries = summaries
            self.claudeSessions = claudeSessions
            self.runningApps = runningApps
        }
    }

    /// One session as the board shows it.
    public struct Card: Identifiable, Equatable, Sendable {
        /// Where the session runs and which it is: stable across refreshes.
        public var id: String
        public var title: String
        /// The session's own title (`/rename`), when the row shows one.
        public var sessionTitle: String?
        public var summary: String?
        public var column: Column
        public var state: DisplayedExport.State
        /// The app that shows the session: its owner when known. Nil for a
        /// background session no app lists.
        public var app: String?
        /// The heading the app lists it under.
        public var section: String?
        /// The Mac the session runs on.
        public var host: String
        /// The Mac whose app export the card came from.
        public var seenOn: String
        public var folder: String?
        /// `claude`, `codex`, or nil.
        public var agent: String?
        /// `tmux`, `claude-bg`, `command`, … or `claude-bg` for an unlisted session.
        public var backend: String
        /// The row's lane id in its app; nil for an unlisted session.
        public var laneID: String?
        /// A background session's short id.
        public var sessionID: String?
        /// The conversation id, when known.
        public var conversationID: String?
        /// The tmux session name.
        public var sessionName: String?
        /// When the session's summary was last written, which follows its
        /// last reply; nil when it has none. (A polled list's time is only
        /// when it was read.)
        public var updatedAt: Date?
        /// Whether a terminal in the app has it open.
        public var attached: Bool

        /// Whether the session is running at all.
        public var isRunning: Bool { column != .notRunning }
    }

    // MARK: Script

    /// The frame's marks for one read, each with a fresh nonce so nothing a
    /// file contains can move the frame.
    public struct Marks: Equatable, Sendable {
        public let nonce: String
        public init(nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) {
            self.nonce = nonce
        }
        func mark(_ name: String) -> String { "<<agentsmate:\(nonce):\(name)>>" }
        var export: String { mark("export") }
        var summariesPrefix: String { mark("summaries") }
        var agents: String { mark("agents") }
        var apps: String { mark("apps") }
        var end: String { mark("end") }
    }

    /// The read-only script that prints one Mac's snapshot.
    public static func script(marks: Marks) -> String {
        let q = ShellWords.quote
        return [
            "d=\"${XDG_STATE_HOME:-$HOME/.local/state}/agentsmate\"",
            "for f in \"$d\"/*/displayed.json; do [ -f \"$f\" ] || continue; echo " + q(marks.export) + "; cat \"$f\"; echo; done",
            "for f in \"$HOME\"/Library/Caches/*/agent-summaries.json; do [ -f \"$f\" ] || continue; echo "
                + q(marks.summariesPrefix) + "; cat \"$f\"; echo; done",
            "echo " + q(marks.agents) + "; cat \"$d/claude-agents.json\" 2>/dev/null; echo",
            "echo " + q(marks.apps),
            "ps -axo comm= | sed -n 's#^\\(.*\\.app\\)/Contents/MacOS/[^/]*$#\\1#p' | sort -u | while read -r a; do "
                + "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$a/Contents/Info.plist\" 2>/dev/null; done",
            "echo " + q(marks.end),
        ].joined(separator: "\n")
    }

    /// The snapshot in a Mac's output, or nil when it did not answer to the end.
    public static func parse(_ output: String, host: String, marks: Marks, now: Date = Date()) -> HostSnapshot? {
        let lines = output.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.filter({ $0 == marks.end }).count == 1 else { return nil }
        var snapshot = HostSnapshot(host: host)
        var current: String?
        var body: [String] = []
        var apps: Set<String> = []
        var sawApps = false
        func flush() {
            defer { body = [] }
            guard let current else { return }
            let data = Data(body.joined(separator: "\n").utf8)
            switch current {
            case "export":
                if let export = DisplayedExport.decode(data) { snapshot.exports.append(export) }
            case "summaries":
                for summary in summaries(in: data) {
                    if let have = snapshot.summaries[summary.conversationID],
                       (have.generatedAt ?? .distantPast) >= (summary.generatedAt ?? .distantPast) { continue }
                    snapshot.summaries[summary.conversationID] = summary
                }
            case "agents":
                snapshot.claudeSessions = ClaudeAgentsList.parse(data, includeInteractive: false, now: now)
            case "apps":
                sawApps = true
                apps.formUnion(body.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            default: break
            }
        }
        for line in lines {
            let section: String? = switch line {
            case marks.export: "export"
            case marks.summariesPrefix: "summaries"
            case marks.agents: "agents"
            case marks.apps: "apps"
            case marks.end: "end"
            default: nil
            }
            if let section {
                flush()
                if section == "end" { break }
                current = section
            } else {
                body.append(line)
            }
        }
        if sawApps { snapshot.runningApps = apps }
        return snapshot
    }

    /// The summaries in one app's `agent-summaries.json`, each tied to the
    /// conversation its transcript file names.
    static func summaries(in data: Data) -> [Summary] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let iso = ISO8601DateFormatter()
        return object.values.compactMap { value in
            guard let fields = value as? [String: Any], let text = fields["summary"] as? String, !text.isEmpty,
                  let source = fields["source"] as? String,
                  let conversation = conversationID(inTranscript: source) else { return nil }
            let at = (fields["generatedAt"] as? String).flatMap { iso.date(from: $0) }
            return Summary(text: text, generatedAt: at, conversationID: conversation)
        }
    }

    /// The conversation id a transcript's file name ends with: a UUID.
    static func conversationID(inTranscript path: String) -> String? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard name.count >= 36 else { return nil }
        let tail = String(name.suffix(36)).lowercased()
        return UUID(uuidString: tail) != nil ? tail : nil
    }

    // MARK: Cards

    /// One card per session across every snapshot.
    ///
    /// The same session can be listed by several apps and seen from several
    /// Macs. It is one card, keyed by the Mac it runs on and its id (its
    /// short id, else its conversation, else its tmux name, else its lane).
    /// The copy kept is the one an app on `localHost` lists, so opening it
    /// opens it here; then the copy from the app that owns the session; then
    /// the most urgent. An export from an app that is no longer running is
    /// stale and ignored. Background sessions no app lists get a card of
    /// their own with no app.
    public static func cards(from snapshots: [HostSnapshot], localHost: String) -> [Card] {
        var byKey: [String: (card: Card, rank: [Int])] = [:]
        var summaries: [String: Summary] = [:]
        for snapshot in snapshots {
            for (key, summary) in snapshot.summaries {
                if let have = summaries[key], (have.generatedAt ?? .distantPast) >= (summary.generatedAt ?? .distantPast) { continue }
                summaries[key] = summary
            }
        }
        // Short id to conversation id, from every Mac's background list.
        var conversations: [String: String] = [:]
        for snapshot in snapshots {
            for record in snapshot.claudeSessions {
                guard let id = record.agentID else { continue }
                if let full = record.sessionID { conversations[snapshot.host + "\u{1}" + id] = full.lowercased() }
            }
        }

        for snapshot in snapshots {
            for export in snapshot.exports {
                let bundle = export.app.bundleID
                if let running = snapshot.runningApps, !running.contains(bundle) { continue }
                let rows = export.allAgents.isEmpty ? export.rows : export.allAgents
                for row in rows {
                    let host = (row.host?.isEmpty == false ? row.host! : snapshot.host)
                    let short = row.sessionID.flatMap { $0.isEmpty ? nil : $0 }
                    var conversation = row.attachedSessionID.flatMap { $0.count >= 32 ? $0.lowercased() : nil }
                    if conversation == nil, let short { conversation = conversations[host + "\u{1}" + short] }
                    let identity = short.map { "id:" + $0 } ?? conversation.map { "conv:" + $0 }
                        ?? row.sessionName.map { "tmux:" + $0 } ?? "lane:" + row.laneID
                    let key = host.lowercased() + "\u{1}" + identity
                    let column = Column.of(row: row)
                    let summary = conversation.flatMap { summaries[$0] }
                        ?? short.flatMap { id in summaries.first { $0.key.hasPrefix(id.lowercased()) }?.value }
                    let card = Card(id: key, title: row.title, sessionTitle: row.sessionTitle, summary: summary?.text,
                                    column: column, state: row.state, app: row.ownerApp ?? bundle, section: row.section,
                                    host: host, seenOn: snapshot.host, folder: row.folder, agent: row.agent,
                                    backend: row.backend, laneID: row.laneID, sessionID: short,
                                    conversationID: conversation, sessionName: row.sessionName,
                                    updatedAt: summary?.generatedAt,
                                    attached: row.attached)
                    // Lower ranks win: listed here, listed by its owner, urgent, open.
                    let rank = [snapshot.host == localHost ? 0 : 1,
                                (row.ownerApp == nil || row.ownerApp == bundle) ? 0 : 1,
                                column.urgency,
                                row.attached ? 0 : 1]
                    if let have = byKey[key], have.rank.lexicographicallyPrecedes(rank) || have.rank == rank { continue }
                    byKey[key] = (card, rank)
                }
            }
        }

        // Background sessions no app lists.
        for snapshot in snapshots {
            for record in snapshot.claudeSessions where record.state != .ended {
                guard let id = record.agentID else { continue }
                let key = snapshot.host.lowercased() + "\u{1}id:" + id
                if byKey[key] != nil { continue }
                let conversation = record.sessionID?.lowercased()
                if let conversation, byKey.values.contains(where: { $0.card.conversationID == conversation }) { continue }
                let column = Column.of(state: record.state)
                let card = Card(id: key, title: record.lane ?? id, sessionTitle: nil,
                                summary: conversation.flatMap { summaries[$0]?.text }, column: column,
                                state: column == .needsYou ? .needsYou : column == .working ? .working : .idle,
                                app: nil, section: nil, host: snapshot.host, seenOn: snapshot.host,
                                folder: record.directory, agent: "claude", backend: "claude-bg", laneID: nil,
                                sessionID: id, conversationID: conversation, sessionName: nil,
                                updatedAt: conversation.flatMap { summaries[$0]?.generatedAt }, attached: false)
                byKey[key] = (card, [2, 1, column.urgency, 1])
            }
        }

        return byKey.values.map(\.card).sorted { a, b in
            if a.column != b.column { return a.column.urgency < b.column.urgency }
            let at = a.updatedAt ?? .distantPast, bt = b.updatedAt ?? .distantPast
            if at != bt { return at > bt }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

/// POSIX shell single-quoting, for the scripts this module hands to `sh`.
public enum ShellWords {
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
