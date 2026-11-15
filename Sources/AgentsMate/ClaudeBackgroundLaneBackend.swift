import Foundation
import AgentsMateStatus

/// Claude Code's own background sessions as lanes: `claude --bg -n <name>`
/// starts one, `claude attach <name>` draws it, and closing the terminal
/// leaves it running, the way detaching from tmux does.
///
/// Not a default anywhere: an app opts in by registering it. Its status
/// comes from ``ClaudeAgentsStatusSource`` rather than hooks alone. See
/// `docs/backends.md` for how it compares with tmux lanes.
public struct ClaudeBackgroundLaneBackend: LaneBackend {
    public var id: String
    public var displayName: String
    /// The `claude` command; a bare name is found on the login shell's PATH.
    public var claude: String
    /// Extra arguments for a new session, such as `--model`.
    public var startArguments: [String]
    /// The session name for a lane. It must be the same on every device so
    /// they all attach one session; the default is the folder's name.
    public var name: @Sendable (AgentLane) -> String

    public var keepsRunningWhenDetached: Bool { true }

    public init(id: String = "claude-bg", displayName: String = "Claude (background)", claude: String = "claude",
                startArguments: [String] = [], name: @escaping @Sendable (AgentLane) -> String = ClaudeBackgroundLaneBackend.folderName) {
        self.id = id
        self.displayName = displayName
        self.claude = claude
        self.startArguments = startArguments
        self.name = name
    }

    /// The folder's name in lower case, spaces and dots as dashes.
    @Sendable public static func folderName(_ lane: AgentLane) -> String {
        let base = (lane.path as NSString).lastPathComponent.lowercased()
        return base.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    public func launch(for lane: AgentLane, shell: String) -> TerminalLaunch {
        let claude = claude.isEmpty ? "claude" : claude
        let session = ShellQuote.quote(name(lane))
        let start = ([claude, "--bg", "-n", session] + startArguments.map(ShellQuote.quote)).joined(separator: " ")
        // Attach when the session exists; otherwise start it here, then attach.
        let line = "\(claude) attach \(session) 2>/dev/null || { \(start) >/dev/null && exec \(claude) attach \(session); }"
        return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: lane.path)
    }

    public func statusMatch(for lane: AgentLane) -> LaneStatusMatch {
        .lane(name(lane))
    }
}

/// Polls `claude agents --json` and hands its sessions to a ``LaneStatusFeed``.
public struct ClaudeAgentsStatusSource: LaneStatusSource {
    public let binary: URL
    /// Also report interactive sessions, such as Claude running in a tmux
    /// lane, so a lane shows its state before any hook has fired.
    public let includeInteractive: Bool

    public init?(binary: URL? = ClaudeBinary.locate(), includeInteractive: Bool = false) {
        guard let binary else { return nil }
        self.binary = binary
        self.includeInteractive = includeInteractive
    }

    public func records() async -> [LaneStatus] {
        let binary = binary, interactive = includeInteractive
        return await Task.detached { ClaudeAgentsList.fetch(binary: binary, includeInteractive: interactive) }.value
    }
}
