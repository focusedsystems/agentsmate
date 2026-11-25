import Foundation

/// How much of an agent's usage allowance is spent, per window (the
/// five-hour session, the week), and when each resets.
public struct AgentUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var label: String
        /// 0–100.
        public var percent: Double
        public var resetsAt: Date?
        /// How long the window runs, when the source says, so a reset that
        /// has passed can be carried to the next one.
        public var length: TimeInterval?

        public init(label: String, percent: Double, resetsAt: Date? = nil, length: TimeInterval? = nil) {
            self.label = label
            self.percent = percent
            self.resetsAt = resetsAt
            self.length = length
        }
    }

    public var agent: String
    public var windows: [Window]
    /// A note such as "Credits depleted", when the agent reports one.
    public var note: String?
    public var readAt: Date
    /// When a limit reported with no window of its own comes back, when the
    /// source can tell: for Codex's spent credits, the reset Codex reports
    /// for them, else one its window records give.
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
    /// The agent the meter still names, as "Usage unknown", when a read
    /// gives nothing. Nil leaves the agent out until it reports.
    var unknownAgent: String? { get }
}

public extension AgentUsageSource {
    var unknownAgent: String? { nil }
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
///
/// When Codex reports a limit reached with no window of its own (spent
/// workspace credits), the reset comes from, in order: Codex's own account
/// read (``CodexLimitsReader``, what the Codex app shows), the latest window
/// reset a record still gives in the future, then the latest window reset any
/// record gives, rolled forward by its window's length until it is to come,
/// and last the reset an earlier read found (``CodexResetCache``), rolled
/// forward a week at a time.
public struct CodexSessionUsageSource: AgentUsageSource {
    public let root: URL
    public var unknownAgent: String? { "Codex" }
    let signedIn: @Sendable () -> Bool
    let limits: CodexLimitsReader?
    let cache: CodexResetCache?

    /// Reads nothing while Codex is signed out, so the meter leaves it out.
    /// `limits` asks Codex itself for the reset while credits are spent; nil
    /// keeps every read to the session files. `cache` keeps the last reset
    /// found, for a read that finds none; nil keeps none.
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
                signedIn: @escaping @Sendable () -> Bool = { AgentSignIn.codex() },
                limits: CodexLimitsReader? = CodexLimitsReader(),
                cache: CodexResetCache? = CodexResetCache()) {
        self.root = root
        self.signedIn = signedIn
        self.limits = limits
        self.cache = cache
    }

    public func read() -> AgentUsage? {
        guard signedIn() else { return nil }
        let texts = recentSessions().compactMap { tail(of: $0) }
        let now = Date()
        return Self.usage(fromNewestFirst: texts, now: now,
                          authoritative: { limits?.depletedUntil(now: now) },
                          older: { recentSessions(limit: 20, maxAge: nil).compactMap { tail(of: $0) } },
                          cached: { cache?.read() }, remember: { cache?.write($0) })
    }

    /// The usage in session text, newest file first: the newest record's.
    /// When that record says a limit is reached and gives no reset, the reset
    /// comes from `authoritative`, else the records' windows: the latest
    /// reset still to come, else the latest one rolled forward by its window
    /// length. `older` gives more text, read only when the first gives no
    /// window at all. With none of those, the `cached` reset an earlier read
    /// found stands in, rolled forward a week at a time; every reset found
    /// while depleted is passed to `remember` for that.
    static func usage(fromNewestFirst texts: [String], now: Date = Date(),
                      authoritative: () -> Date? = { nil },
                      older: () -> [String] = { [] },
                      cached: () -> Date? = { nil },
                      remember: (Date) -> Void = { _ in }) -> AgentUsage? {
        let usage = foundUsage(fromNewestFirst: texts, now: now, authoritative: authoritative, older: older)
        guard var usage, usage.isDepleted else { return usage }
        if let reset = usage.depletedUntil {
            remember(reset)
        } else if let saved = cached() {
            usage.resetsAt = nextReset(of: [.init(label: "Saved", percent: 100, resetsAt: saved, length: 7 * 24 * 3600)],
                                       after: now)
        }
        return usage
    }

    static func foundUsage(fromNewestFirst texts: [String], now: Date,
                           authoritative: () -> Date?, older: () -> [String]) -> AgentUsage? {
        var latest: AgentUsage?
        var windows: [AgentUsage.Window] = []
        for text in texts {
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let usage = parse(line: String(line), now: now) else { continue }
                if latest == nil { latest = usage }
                windows += usage.windows
            }
        }
        guard var usage = latest else { return nil }
        guard usage.isDepleted, usage.depletedUntil == nil else { return usage }
        if let reset = authoritative(), reset > now {
            usage.resetsAt = reset
            return usage
        }
        if !windows.contains(where: { $0.resetsAt != nil }) {
            for text in older() {
                for line in text.split(separator: "\n") where line.contains("\"rate_limits\"") {
                    windows += parse(line: String(line), now: now)?.windows ?? []
                }
            }
        }
        usage.resetsAt = nextReset(of: windows, after: now)
        return usage
    }

    /// The latest reset still to come; failing that, the latest reset rolled
    /// forward by its window's length to the first one after `now`.
    static func nextReset(of windows: [AgentUsage.Window], after now: Date) -> Date? {
        if let future = windows.compactMap(\.resetsAt).filter({ $0 > now }).max() { return future }
        return windows.compactMap { window -> Date? in
            guard let reset = window.resetsAt, let length = window.length, length > 0 else { return nil }
            let periods = (now.timeIntervalSince(reset) / length).rounded(.down) + 1
            return reset.addingTimeInterval(periods * length)
        }.max()
    }

    /// Codex files sessions by date: the few newest, newest first, of those
    /// changed within `maxAge` (any age when nil).
    func recentSessions(limit: Int = 5, maxAge: TimeInterval? = 7 * 24 * 3600) -> [URL] {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var found: [(URL, Date)] = []
        let cutoff = maxAge.map { Date().addingTimeInterval(-$0) } ?? .distantPast
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
            windows.append(.init(label: label, percent: used, resetsAt: resets, length: minutes.map { Double($0) * 60 }))
        }
        let reached = (limits["rate_limit_reached_type"] as? String).map {
            $0.replacingOccurrences(of: "_", with: " ").capitalized
        }
        guard !windows.isEmpty || reached != nil else { return nil }
        // A spend limit of the member's own carries its reset.
        let spendReset = ((limits["individual_limit"] as? [String: Any])?["resets_at"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        return AgentUsage(agent: "Codex", windows: windows, note: reached, resetsAt: spendReset)
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

/// When Codex's spent limit resets, as Codex itself reports it: the account
/// read (`account/rateLimits/read`) of `codex app-server`, the same answer
/// the Codex app gives. It runs the command at most once per ``interval``,
/// at background QoS with a timeout, and answers from the last run between.
public final class CodexLimitsReader: @unchecked Sendable {
    public let interval: TimeInterval
    let run: @Sendable () -> String?

    private let lock = NSLock()
    private var lastRun = Date.distantPast
    private var reset: Date?

    /// `executable` is the `codex` command; nil looks for it.
    public convenience init(executable: URL? = nil, interval: TimeInterval = 600, timeout: TimeInterval = 20) {
        self.init(interval: interval) {
            guard let codex = executable ?? CommandLocator.locate("codex") else { return nil }
            return Self.accountLimits(codex: codex, timeout: timeout)
        }
    }

    init(interval: TimeInterval, run: @escaping @Sendable () -> String?) {
        self.interval = interval
        self.run = run
    }

    /// When the spent limit lifts, if it is still to come at `now`.
    public func depletedUntil(now: Date = Date()) -> Date? {
        lock.lock()
        let due = now.timeIntervalSince(lastRun) >= interval
        if due { lastRun = now }
        lock.unlock()
        if due, let output = run() {
            let found = Self.parse(output)
            lock.lock()
            if let found { reset = found }
            lock.unlock()
        }
        lock.lock()
        defer { lock.unlock() }
        return reset.flatMap { $0 > now ? $0 : nil }
    }

    /// The reset in an `account/rateLimits/read` result: the reset Codex
    /// gives for the reached limit, else the member's spend limit's, else
    /// the latest of the full windows'.
    static func parse(_ output: String) -> Date? {
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  result["rateLimits"] != nil || result["rateLimitsByLimitId"] != nil else { continue }
            let date = { (value: Any?) in (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
            if let at = date((result["rateLimitUpsell"] as? [String: Any])?["reset_at"]) { return at }
            var snapshots = (result["rateLimitsByLimitId"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
            if let main = result["rateLimits"] as? [String: Any] { snapshots.insert(main, at: 0) }
            for snapshot in snapshots {
                if let at = date((snapshot["individualLimit"] as? [String: Any])?["resetsAt"]) { return at }
            }
            let full = snapshots.flatMap { snapshot in
                ["primary", "secondary"].compactMap { snapshot[$0] as? [String: Any] }
            }.filter { (($0["usedPercent"] as? NSNumber)?.doubleValue ?? 0) >= 100 }
            return full.compactMap { date($0["resetsAt"]) }.max()
        }
        return nil
    }

    /// Starts `codex app-server`, asks for the account's limits and returns
    /// the reply line, or nil when none comes within `timeout`.
    static func accountLimits(codex: URL, timeout: TimeInterval) -> String? {
        let process = Process()
        process.qualityOfService = .background
        process.executableURL = codex
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let replied = DispatchSemaphore(value: 0)
        let buffer = LockedBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; replied.signal(); return }
            if buffer.append(chunk) { replied.signal() }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agentsmate","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ].joined(separator: "\n") + "\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))
        _ = replied.wait(timeout: .now() + timeout)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        return buffer.reply
    }

    /// The app server's output as it arrives, until the reply to request 2.
    private final class LockedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var reply: String? {
            get { lock.lock(); defer { lock.unlock() }; return _reply }
            set { lock.lock(); _reply = newValue; lock.unlock() }
        }
        private var _reply: String?

        /// Adds a chunk; true once the reply has arrived.
        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard _reply == nil else { return true }
            data.append(chunk)
            let text = String(decoding: data, as: UTF8.self)
            if let line = text.split(separator: "\n").first(where: { $0.contains(#""id":2"#) && $0.hasSuffix("}") }) {
                _reply = String(line)
                return true
            }
            return false
        }
    }
}

/// The last reset a read found for Codex's spent limit, kept in a small file
/// beside the lane status folder (`agentsmate/usage/codex-reset.json` in the
/// state folder), so a read that can reach nothing still has a date.
public struct CodexResetCache: Sendable {
    public let url: URL

    public init(url: URL = LaneStatusDirectory.default().url.deletingLastPathComponent()
        .appendingPathComponent("usage/codex-reset.json")) {
        self.url = url
    }

    struct Record: Codable { var resetsAt: Date }

    public func read() -> Date? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? LaneStatusDirectory.decoder.decode(Record.self, from: data))?.resetsAt
    }

    /// Saves `date` to the second, writing only when it differs from what
    /// is kept.
    public func write(_ date: Date) {
        let date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
        guard read() != date else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? LaneStatusDirectory.encoder.encode(Record(resetsAt: date)).write(to: url, options: .atomic)
    }
}

/// Where a command-line tool is installed. A GUI app does not inherit the
/// person's shell PATH, so the usual install locations are checked first,
/// then a login shell is asked.
enum CommandLocator {
    static func locate(_ name: String, extra: [String] = []) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = extra + ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return loginShellLookup(name)
    }

    static func loginShellLookup(_ name: String) -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        // Callers may wait on this while an app starts, so it must not queue
        // behind background work.
        process.qualityOfService = .userInitiated
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
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
    public var unknownAgent: String? { agent }
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
