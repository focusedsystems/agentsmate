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
        [claude(host: claudeHost, fallbackHosts: fallbackHosts), CodexSessionUsageSource()]
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
        let registry = AgentHosts.load()
        let own = selfNames ?? AgentHosts.thisMacNames.union(registry.map { [$0.selfName] } ?? [])
        let named = fallbackHosts ?? registry?.hub.map { [$0.name] } ?? []
        var seen = Set<String>()
        let hosts = ([host ?? ""] + named).map { $0.trimmingCharacters(in: .whitespaces) }.filter { name in
            TmuxLaneSessions.isValidHost(name) && !own.contains(name) && seen.insert(name).inserted
        }
        let remotes = hosts.map { name in
            KeyValueUsageCommandSource(agent: "Claude", command: [
                "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", name, "cat " + claudeCachePath,
            ], interval: 60)
        }
        return remotes.isEmpty ? local : FallbackUsageSource(primary: local, fallbacks: remotes)
    }
}

/// A reading from `primary` while it has one that is current, else the
/// freshest current reading among `fallbacks`. The fallbacks are not read
/// while the primary has a reading, so a Mac that runs its own agents never
/// touches the network. With no current reading anywhere, the primary's own
/// answer stands, which for a stale file is "Usage unknown".
///
/// Blocks while a fallback runs; call it off the main thread, as
/// ``AgentUsageModel`` does.
public struct FallbackUsageSource: AgentUsageSource {
    public let primary: any AgentUsageSource
    public let fallbacks: [any AgentUsageSource]
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
        if let own, !own.windows.isEmpty { return own }
        let found = fallbacks.compactMap { $0.read()?.current(at: now) }.filter { !$0.windows.isEmpty }
        return found.max { $0.readAt < $1.readAt } ?? own
    }
}
