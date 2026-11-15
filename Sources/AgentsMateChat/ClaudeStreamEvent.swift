import Foundation
@_exported import enum AgentsMateStatus.ClaudeBinary

/// One event from a headless Claude Code conversation as the assistant responds.
public enum ClaudeStreamEvent: Sendable, Equatable {
    /// Claude confirmed the session is live, in `cwd`.
    case sessionStarted(sessionID: String, cwd: String?)
    /// An incremental chunk of assistant text.
    case textDelta(String)
    /// The assistant invoked a tool; `summary` previews its input.
    case toolUse(name: String, summary: String)
    /// A tool returned; `summary` previews its result.
    case toolResult(summary: String, isError: Bool)
    /// The current assistant turn finished.
    case turnComplete(isError: Bool)
    /// The process itself failed: a crash, an auth error, a bad invocation.
    case providerError(String)
}

public enum ClaudeStreamError: Error, Equatable {
    case notStarted
}
