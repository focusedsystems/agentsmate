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
    /// `claudeHost` names a Mac whose cache is read over `ssh` instead, for
    /// a Mac whose agents run elsewhere and never write the cache
    /// themselves. A value `ssh` could not take safely
    /// (``TmuxLaneSessions/isValidHost(_:)``) is ignored.
    public static func standard(claudeHost: String? = nil) -> [any AgentUsageSource] {
        [claude(host: claudeHost), CodexSessionUsageSource()]
    }

    /// Claude's source: this Mac's cache, or `host`'s over `ssh`.
    public static func claude(host: String? = nil) -> any AgentUsageSource {
        let host = host?.trimmingCharacters(in: .whitespaces) ?? ""
        if TmuxLaneSessions.isValidHost(host) {
            return KeyValueUsageCommandSource(agent: "Claude", command: [
                "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", host, "cat " + claudeCachePath,
            ])
        }
        return KeyValueUsageFileSource(
            url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(claudeCachePath),
            agent: "Claude", signedIn: { AgentSignIn.claude() })
    }
}
