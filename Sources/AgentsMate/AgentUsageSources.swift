import Foundation
import AgentsMateStatus

/// The usage sources every app starts with, so the sidebar's foot shows the
/// Claude and Codex meters whichever backend the app defaults to.
public enum AgentUsageSources {
    /// Where Claude's status-line helper keeps its usage cache, under home.
    public static let claudeCachePath = ".claude/.statusline-usage-cache"

    /// Claude's limits from the status-line cache, and Codex's from the
    /// session files it keeps under `~/.codex`. Each agent stays in the
    /// footer as "Usage unknown" until it has a current reading.
    ///
    /// Claude's cache is read on this Mac first. When it is missing or too
    /// old, because this Mac runs no agent of its own, the cache on another
    /// Mac is read over `ssh` and the freshest reading shown. `fallbackHosts`
    /// names those Macs; nil takes the hub of the agent hosts registry
    /// (``AgentHosts``), so an app that sets nothing still reads the Mac its
    /// agents run on. Pass an empty array to read this Mac only. `claudeHost`
    /// is an override tried first. A name `ssh` could not take safely
    /// (``TmuxLaneSessions/isValidHost(_:)``) is ignored, and so is this Mac.
    public static func standard(claudeHost: String? = nil, fallbackHosts: [String]? = nil) -> [any AgentUsageSource] {
        [claude(host: claudeHost, fallbackHosts: fallbackHosts), codex(fallbackHosts: fallbackHosts)]
    }

    /// Codex's source: this Mac's session files, and the newest session files
    /// on the registry's hub (or `fallbackHosts`), read over `ssh` at most
    /// once a minute. The freshest reading wins, so a Mac that last ran Codex
    /// days ago shows the hub's figures rather than its own old ones.
    public static func codex(fallbackHosts: [String]? = nil, selfNames: Set<String>? = nil) -> any AgentUsageSource {
        let local = CodexSessionUsageSource()
        let hosts = remoteHosts(nil, fallbackHosts: fallbackHosts, selfNames: selfNames)
        let remotes = hosts.map { name in
            CodexRemoteUsageSource(command: ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", name,
                                             CodexRemoteUsageSource.script])
        }
        return remotes.isEmpty ? local : FallbackUsageSource(primary: local, fallbacks: remotes)
    }

    static func remoteHosts(_ host: String?, fallbackHosts: [String]?, selfNames: Set<String>?) -> [String] {
        let registry = AgentHosts.load()
        let own = selfNames ?? AgentHosts.thisMacNames.union(registry.map { [$0.selfName] } ?? [])
        let named = fallbackHosts ?? registry?.hub.map { [$0.name] } ?? []
        var seen = Set<String>()
        return ([host ?? ""] + named).map { $0.trimmingCharacters(in: .whitespaces) }.filter { name in
            TmuxLaneSessions.isValidHost(name) && !own.contains(name) && seen.insert(name).inserted
        }
    }

    /// Claude's source: this Mac's cache, and when that has no current
    /// reading, the freshest one among the caches of `host` and
    /// `fallbackHosts` (the registry's hub when nil), each read over `ssh`
    /// at most once a minute.
    public static func claude(host: String? = nil, fallbackHosts: [String]? = nil,
                              selfNames: Set<String>? = nil) -> any AgentUsageSource {
        let local = KeyValueUsageFileSource(
            url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(claudeCachePath),
            agent: "Claude", signedIn: { AgentSignIn.claude() })
        let hosts = remoteHosts(host, fallbackHosts: fallbackHosts, selfNames: selfNames)
        let remotes = hosts.map { name in
            KeyValueUsageCommandSource(agent: "Claude", command: [
                "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", name, "cat " + claudeCachePath,
            ], interval: 60)
        }
        return remotes.isEmpty ? local : FallbackUsageSource(primary: local, fallbacks: remotes)
    }
}

/// `primary`'s reading while it is under ``freshEnough`` old, so a Mac that
/// runs its own agents never touches the network; otherwise the freshest
/// current reading among `primary` and `fallbacks`, so this Mac's old reading
/// never hides a newer one from the Mac its agents run on. With no current reading anywhere, the
/// primary's own answer stands, which for a stale file is "Usage unknown".
///
/// Blocks while a fallback runs; call it off the main thread, as
/// ``AgentUsageModel`` does.
public struct FallbackUsageSource: AgentUsageSource {
    public let primary: any AgentUsageSource
    public let fallbacks: [any AgentUsageSource]
    /// Ten minutes.
    public static let freshEnough: TimeInterval = 600
    let clock: @Sendable () -> Date

    public init(primary: any AgentUsageSource, fallbacks: [any AgentUsageSource]) {
        self.init(primary: primary, fallbacks: fallbacks, clock: { Date() })
    }

    init(primary: any AgentUsageSource, fallbacks: [any AgentUsageSource], clock: @escaping @Sendable () -> Date) {
        self.primary = primary
        self.fallbacks = fallbacks
        self.clock = clock
    }

    public var unknownAgent: String? { primary.unknownAgent ?? fallbacks.lazy.compactMap(\.unknownAgent).first }

    public func read() -> AgentUsage? {
        let now = clock()
        let own = primary.read()?.current(at: now)
        // A reading this recent means this Mac runs the agent itself: no
        // network call is made for it.
        if let own, !own.windows.isEmpty, now.timeIntervalSince(own.readAt) < Self.freshEnough { return own }
        let found = ([own].compactMap { $0 } + fallbacks.compactMap { $0.read()?.current(at: now) })
            .filter { !$0.windows.isEmpty }
        return found.max { $0.readAt < $1.readAt } ?? own
    }
}

/// Codex usage from another Mac: the tails of its newest session files, read
/// by `command` (an `ssh` running ``script``) at most once per `interval`.
/// Between runs the last text is parsed again, so a reset that passes still
/// takes its window away.
public final class CodexRemoteUsageSource: AgentUsageSource, @unchecked Sendable {
    public var unknownAgent: String? { "Codex" }
    public let command: [String]
    public let interval: TimeInterval
    let runner: @Sendable ([String], TimeInterval) -> String
    private let lock = NSLock()
    private var texts: [String] = []
    private var nextRun = Date.distantPast

    /// Prints the last 256 KB of each of the three newest session files,
    /// newest first, each followed by ``separator``.
    public static let separator = "@@agentsmate-codex-next@@"
    public static let script = "cd ~/.codex/sessions 2>/dev/null || exit 0; ls -t */*/*/*.jsonl 2>/dev/null | head -3 | "
        + "while read -r f; do tail -c 262144 \"$f\"; echo; echo '\(separator)'; done"

    public convenience init(command: [String], interval: TimeInterval = 60) {
        self.init(command: command, interval: interval, runner: { argv, timeout in
            LaneRowMetadataReader.run(argv[0], Array(argv.dropFirst()), timeout: timeout)
        })
    }

    init(command: [String], interval: TimeInterval, runner: @escaping @Sendable ([String], TimeInterval) -> String) {
        self.command = command
        self.interval = interval
        self.runner = runner
    }

    /// Blocks while the command runs; call it off the main thread.
    public func read() -> AgentUsage? {
        guard let executable = command.first, executable.hasPrefix("/") else { return nil }
        let now = Date()
        lock.lock()
        let due = now >= nextRun
        if due { nextRun = now.addingTimeInterval(interval) }
        lock.unlock()
        if due {
            let parts = Self.split(runner(command, 15))
            lock.lock()
            if !parts.isEmpty { texts = parts }
            lock.unlock()
        }
        lock.lock()
        let current = texts
        lock.unlock()
        return CodexSessionUsageSource.usage(fromNewestFirst: current, now: now)
    }

    static func split(_ output: String) -> [String] {
        output.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
