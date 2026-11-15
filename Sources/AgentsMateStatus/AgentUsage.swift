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

    public init(agent: String, windows: [Window], note: String? = nil, readAt: Date = Date()) {
        self.agent = agent
        self.windows = windows
        self.note = note
        self.readAt = readAt
    }

    /// The fullest window, which is the one that stops work first.
    public var fullest: Window? { windows.max { $0.percent < $1.percent } }
}

/// Somewhere usage can be read from without a network call.
public protocol AgentUsageSource: Sendable {
    func read() -> AgentUsage?
}

/// Codex's limits, from the `rate_limits` it records in its newest session
/// file under `~/.codex/sessions`.
public struct CodexSessionUsageSource: AgentUsageSource {
    public let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) {
        self.root = root
    }

    public func read() -> AgentUsage? {
        guard let file = newestSession(), let text = tail(of: file) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let usage = Self.parse(line: String(line)) { return usage }
        }
        return nil
    }

    /// Codex files sessions by date; the newest is found in the last few days.
    func newestSession() -> URL? {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (URL, Date)?
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date > cutoff else { continue }
            if best.map({ date > $0.1 }) ?? true { best = (url, date) }
        }
        return best?.0
    }

    func tail(of url: URL, bytes: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }

    static func parse(line: String) -> AgentUsage? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = find("rate_limits", in: object) as? [String: Any] else { return nil }
        var windows: [AgentUsage.Window] = []
        for (key, fallback) in [("primary", "Session"), ("secondary", "Week")] {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            var resets: Date?
            if let at = (w["resets_at"] as? NSNumber)?.doubleValue { resets = Date(timeIntervalSince1970: at) }
            else if let seconds = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { resets = Date().addingTimeInterval(seconds) }
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
/// `UTILIZATION` and `RESETS_AT` for the session window and
/// `WEEKLY_UTILIZATION` and `WEEKLY_RESETS_AT` for the week (ISO 8601
/// dates). The app names the file and the agent it describes.
public struct KeyValueUsageFileSource: AgentUsageSource {
    public let url: URL
    public let agent: String

    public init(url: URL, agent: String) {
        self.url = url
        self.agent = agent
    }

    public func read() -> AgentUsage? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.parse(text, agent: agent)
    }

    static func parse(_ text: String, agent: String) -> AgentUsage? {
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
        let read = values["TIMESTAMP"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? Date()
        return AgentUsage(agent: agent, windows: windows, readAt: read)
    }
}
