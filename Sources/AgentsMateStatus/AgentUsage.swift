import Foundation

/// How much of an agent's usage allowance is spent, per window (the
/// five-hour session, the week), and when each resets.
public struct AgentUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var label: String
        /// 0–100.
        public var percent: Double
        public var resetsAt: Date?

        public init(label: String, percent: Double, resetsAt: Date? = nil) {
            self.label = label
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    public var agent: String
    public var windows: [Window]
    /// A note such as "Credits depleted", when the agent reports one.
    public var note: String?
    public var readAt: Date
    /// When a limit reported with no window of its own comes back, when the
    /// source can tell: for Codex's spent credits, the latest window reset
    /// its earlier records still give in the future.
    public var resetsAt: Date?

    public init(agent: String, windows: [Window], note: String? = nil, readAt: Date = Date(), resetsAt: Date? = nil) {
        self.agent = agent
        self.windows = windows
        self.note = note
        self.readAt = readAt
        self.resetsAt = resetsAt
    }

    /// The fullest window, which is the one that stops work first.
    public var fullest: Window? { windows.max { $0.percent < $1.percent } }

    /// Whether the agent can do no more work until something resets: a
    /// window at 100%, or a limit it reports reached (a note such as
    /// "Credits Depleted") with no window to show.
    public var isDepleted: Bool {
        if windows.contains(where: { $0.percent >= 100 }) { return true }
        return windows.isEmpty && note != nil && !isUnknown
    }

    /// When a depleted agent can work again: the latest reset of the full
    /// windows, since all of them must clear, else ``resetsAt``. Nil when
    /// the agent is not depleted or nothing gives a reset.
    public var depletedUntil: Date? {
        guard isDepleted else { return nil }
        return windows.filter { $0.percent >= 100 }.compactMap(\.resetsAt).max() ?? resetsAt
    }

    /// The note an agent gets when nothing it last reported still holds.
    public static let unknownNote = "Usage unknown"

    /// Whether nothing current is known: no window, only ``unknownNote``.
    public var isUnknown: Bool { windows.isEmpty && note == Self.unknownNote }

    /// What still holds at `now`. A window whose reset has passed is left
    /// out, since its figure belongs to a period that is over; a reading
    /// older than `maxAge` keeps nothing. With no window left the agent is
    /// unknown: ``unknownNote``, never the old figures.
    public func current(at now: Date = Date(), maxAge: TimeInterval? = nil) -> AgentUsage {
        if let maxAge, now.timeIntervalSince(readAt) > maxAge {
            return AgentUsage(agent: agent, windows: [], note: Self.unknownNote, readAt: readAt)
        }
        var current = self
        if let resetsAt, resetsAt <= now { current.resetsAt = nil }
        let kept = windows.filter { window in window.resetsAt.map { $0 > now } ?? true }
        guard kept.count != windows.count else { return current }
        return AgentUsage(agent: agent, windows: kept, note: kept.isEmpty ? Self.unknownNote : note, readAt: readAt,
                          resetsAt: current.resetsAt)
    }
}

/// Somewhere usage can be read from without a network call.
public protocol AgentUsageSource: Sendable {
    func read() -> AgentUsage?
}

/// Whether someone is signed in to an agent on this Mac, from the files the
/// agent keeps, so a meter can leave out an agent nobody set up.
public enum AgentSignIn {
    /// Codex keeps its sign-in in `auth.json` under `CODEX_HOME`.
    public static func codex(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
    }

    /// Claude Code records the signed-in account in `.claude.json`
    /// (`oauthAccount`); an API key in the environment counts too.
    public static func claude(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["ANTHROPIC_API_KEY"]?.isEmpty == false { return true }
        let config = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["oauthAccount"] != nil
    }
}

/// Codex's limits, from the `rate_limits` it records in its newest session
/// file under `~/.codex/sessions`.
public struct CodexSessionUsageSource: AgentUsageSource {
    public let root: URL
    let signedIn: @Sendable () -> Bool

    /// Reads nothing while Codex is signed out, so the meter leaves it out.
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
                signedIn: @escaping @Sendable () -> Bool = { AgentSignIn.codex() }) {
        self.root = root
        self.signedIn = signedIn
    }

    public func read() -> AgentUsage? {
        guard signedIn() else { return nil }
        let texts = recentSessions().compactMap { tail(of: $0) }
        return Self.usage(fromNewestFirst: texts)
    }

    /// The usage in session text, newest file first: the newest record's.
    /// When that record says a limit is reached and gives no reset (Codex's
    /// spent credits carry no window), the latest window reset any recent
    /// record still gives in the future stands in for it.
    static func usage(fromNewestFirst texts: [String], now: Date = Date()) -> AgentUsage? {
        var latest: AgentUsage?
        var futureReset: Date?
        for text in texts {
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let usage = parse(line: String(line), now: now) else { continue }
                if latest == nil { latest = usage }
                for reset in usage.windows.compactMap(\.resetsAt) where reset > now {
                    futureReset = max(futureReset ?? reset, reset)
                }
            }
            if latest != nil, latest?.isDepleted != true || latest?.depletedUntil != nil { break }
        }
        guard var usage = latest else { return nil }
        if usage.isDepleted, usage.depletedUntil == nil { usage.resetsAt = futureReset }
        return usage
    }

    /// Codex files sessions by date: the few newest of the last week, newest
    /// first.
    func recentSessions(limit: Int = 5) -> [URL] {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var found: [(URL, Date)] = []
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date > cutoff else { continue }
            found.append((url, date))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// The newest session file of the last week.
    func newestSession() -> URL? { recentSessions(limit: 1).first }

    func tail(of url: URL, bytes: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }

    static func parse(line: String, now: Date = Date()) -> AgentUsage? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = find("rate_limits", in: object) as? [String: Any] else { return nil }
        var windows: [AgentUsage.Window] = []
        for (key, fallback) in [("primary", "Session"), ("secondary", "Week")] {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            var resets: Date?
            if let at = (w["resets_at"] as? NSNumber)?.doubleValue { resets = Date(timeIntervalSince1970: at) }
            else if let seconds = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { resets = now.addingTimeInterval(seconds) }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue
            let label = minutes.map { $0 >= 7 * 24 * 60 ? "Week" : $0 >= 24 * 60 ? "Day" : "\($0 / 60)h" } ?? fallback
            windows.append(.init(label: label, percent: used, resetsAt: resets))
        }
        let reached = (limits["rate_limit_reached_type"] as? String).map {
            $0.replacingOccurrences(of: "_", with: " ").capitalized
        }
        guard !windows.isEmpty || reached != nil else { return nil }
        return AgentUsage(agent: "Codex", windows: windows, note: reached)
    }

    static func find(_ key: String, in value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            if let hit = dict[key] { return hit }
            for child in dict.values { if let hit = find(key, in: child) { return hit } }
        } else if let array = value as? [Any] {
            for child in array { if let hit = find(key, in: child) { return hit } }
        }
        return nil
    }
}

/// Usage from a `KEY=VALUE` file a status-line helper writes, with
/// `UTILIZATION` and `RESETS_AT` for the session window,
/// `WEEKLY_UTILIZATION` and `WEEKLY_RESETS_AT` for the week (ISO 8601
/// dates), and `TIMESTAMP` (seconds since 1970) for when it was written. The
/// app names the file and the agent it describes.
///
/// The file is only as current as the helper that writes it: on a Mac where
/// no agent has run for a while it holds old figures. A window whose reset
/// has passed is left out, and a file older than ``maxAge`` counts for
/// nothing, so the meter says the agent is unknown rather than showing
/// them.
public struct KeyValueUsageFileSource: AgentUsageSource {
    public let url: URL
    public let agent: String
    /// How old a reading may be and still count; nil, any age.
    public let maxAge: TimeInterval?
    let signedIn: @Sendable () -> Bool

    /// An hour: a status line rewrites the file every few minutes while an
    /// agent runs, so an older one was written by a Mac that is not in use.
    public static let defaultMaxAge: TimeInterval = 3600

    /// `signedIn` says whether the agent is set up; while it is false the
    /// source reads nothing, so a stale file does not show a signed-out agent.
    public init(url: URL, agent: String, maxAge: TimeInterval? = KeyValueUsageFileSource.defaultMaxAge,
                signedIn: @escaping @Sendable () -> Bool = { true }) {
        self.url = url
        self.agent = agent
        self.maxAge = maxAge
        self.signedIn = signedIn
    }

    public func read() -> AgentUsage? {
        guard signedIn(), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.usage(from: text, agent: agent, maxAge: maxAge)
    }

    /// The usage in a file's text as it stands at `now`; see
    /// ``AgentUsage/current(at:maxAge:)``. Nil when the text holds none.
    public static func usage(from text: String, agent: String, now: Date = Date(),
                             maxAge: TimeInterval? = defaultMaxAge) -> AgentUsage? {
        parse(text, agent: agent, now: now)?.current(at: now, maxAge: maxAge)
    }

    static func parse(_ text: String, agent: String, now: Date = Date()) -> AgentUsage? {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        let iso = ISO8601DateFormatter()
        var windows: [AgentUsage.Window] = []
        if let used = values["UTILIZATION"].flatMap(Double.init) {
            windows.append(.init(label: "Session", percent: used, resetsAt: values["RESETS_AT"].flatMap(iso.date(from:))))
        }
        if let used = values["WEEKLY_UTILIZATION"].flatMap(Double.init) {
            windows.append(.init(label: "Week", percent: used, resetsAt: values["WEEKLY_RESETS_AT"].flatMap(iso.date(from:))))
        }
        guard !windows.isEmpty else { return nil }
        let read = values["TIMESTAMP"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? now
        return AgentUsage(agent: agent, windows: windows, readAt: read)
    }
}
