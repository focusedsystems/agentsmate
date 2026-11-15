import Foundation
import AgentsMateStatus

/// One row in the lane list: something an agent can be opened in.
///
/// The app decides what its lanes are (a folder per area, a repository, a
/// session the person started) and which backend runs each one. Nothing in
/// AgentsMate knows a path or a command of its own.
public struct AgentLane: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// An SF Symbol name.
    public var symbol: String
    /// `#RRGGBB`, or nil for the accent colour.
    public var tintHex: String?
    /// The folder the lane opens in. Nil is the home folder.
    public var directory: URL?
    /// Which registered ``LaneBackend`` runs this lane.
    public var backendID: String
    /// Lanes the person opened themselves can be closed; an app's fixed lanes cannot.
    public var isClosable: Bool
    /// Overrides how the backend finds this lane's status record.
    public var statusMatch: LaneStatusMatch?
    /// The section the lane starts in, such as a repository's host. The
    /// person can move it; their choice is kept in ``LaneLayout``.
    public var section: String?

    public init(id: String, title: String, symbol: String = "terminal", tintHex: String? = nil,
                directory: URL? = nil, backendID: String, isClosable: Bool = false,
                statusMatch: LaneStatusMatch? = nil, section: String? = nil) {
        self.section = section
        self.id = id
        self.title = title
        self.symbol = symbol
        self.tintHex = tintHex
        self.directory = directory
        self.backendID = backendID
        self.isClosable = isClosable
        self.statusMatch = statusMatch
    }

    public var path: String {
        (directory ?? FileManager.default.homeDirectoryForCurrentUser).path
    }
}

/// What a lane's terminal runs.
public struct TerminalLaunch: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// Added to the app's environment, after AgentsMate's own changes.
    public var environment: [String: String]
    public var directory: String

    public init(executable: String, arguments: [String], environment: [String: String] = [:], directory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }
}

/// How lanes of one kind are started and how their status is found.
///
/// Today's backend is ``CommandLaneBackend``: a command in a login shell,
/// typically a wrapper that attaches a persistent tmux session, so the lane
/// opened here is the same one other terminals and devices see. A backend
/// that attaches some other kind of persistent session — a daemon's own
/// background sessions, or a model served elsewhere — conforms to the same
/// protocol; see `docs/backends.md`.
public protocol LaneBackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Whether ending the local terminal leaves the agent running, so
    /// detaching and reattaching keeps the conversation.
    var keepsRunningWhenDetached: Bool { get }
    /// The process that draws this lane in its terminal.
    func launch(for lane: AgentLane, shell: String) -> TerminalLaunch
    /// How to pick this lane's record out of the status feed.
    func statusMatch(for lane: AgentLane) -> LaneStatusMatch
    /// Whether ``stop(_:)`` ends the lane's session.
    var canStop: Bool { get }
    /// End the lane's persistent session, as closing its workspace in a
    /// terminal multiplexer would. The agent's conversation is kept, so
    /// opening the lane again resumes it.
    func stop(_ lane: AgentLane)
}

public extension LaneBackend {
    var canStop: Bool { false }
    func stop(_ lane: AgentLane) {}
}

/// Runs a command without waiting for it, for stopping a lane.
public enum LaneCommand {
    public static func run(_ arguments: [String]) {
        guard !arguments.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin"
        process.environment = env
        try? process.run()
    }
}

/// A lane that runs one shell command in an interactive login shell, so the
/// person's PATH and tools are there even though the app was started by
/// launchd.
public struct CommandLaneBackend: LaneBackend {
    public var id: String
    public var displayName: String
    /// The command line. Empty runs the login shell itself.
    public var command: String
    /// Append the lane's folder, quoted, as the command's last argument.
    /// Lane wrappers take the folder that way; most programs use the working
    /// directory instead.
    public var passesDirectory: Bool
    /// When the command ends, keep the terminal open at a shell prompt.
    public var returnsToShell: Bool
    /// The agent whose status records describe these lanes (`claude`,
    /// `codex`), or nil for a lane with no status.
    public var statusAgent: String?
    public var keepsRunningWhenDetached: Bool
    /// A file the command writes holding the id of the agent session behind
    /// a lane. When it exists, status is matched by that id; folders are
    /// only the fallback, because several lanes can share one folder.
    public var sessionIDFile: (@Sendable (AgentLane) -> URL?)?
    /// The command that ends a lane's session (`argv`, found on PATH), such
    /// as killing its tmux session. Nil means the lane cannot be stopped here.
    public var stopCommand: (@Sendable (AgentLane) -> [String])?

    public init(id: String, displayName: String, command: String, passesDirectory: Bool = false,
                returnsToShell: Bool = false, statusAgent: String? = nil, keepsRunningWhenDetached: Bool = false,
                sessionIDFile: (@Sendable (AgentLane) -> URL?)? = nil,
                stopCommand: (@Sendable (AgentLane) -> [String])? = nil) {
        self.sessionIDFile = sessionIDFile
        self.stopCommand = stopCommand
        self.id = id
        self.displayName = displayName
        self.command = command
        self.passesDirectory = passesDirectory
        self.returnsToShell = returnsToShell
        self.statusAgent = statusAgent
        self.keepsRunningWhenDetached = keepsRunningWhenDetached
    }

    /// A wrapper that attaches a persistent tmux lane for the folder it is
    /// given, so opening the row again — here, in another terminal, or from
    /// another device — attaches the same conversation.
    public static func tmuxLane(id: String, displayName: String, command: String, statusAgent: String?,
                                sessionIDFile: (@Sendable (AgentLane) -> URL?)? = nil,
                                stopCommand: (@Sendable (AgentLane) -> [String])? = nil) -> CommandLaneBackend {
        CommandLaneBackend(id: id, displayName: displayName, command: command, passesDirectory: true,
                           returnsToShell: false, statusAgent: statusAgent, keepsRunningWhenDetached: true,
                           sessionIDFile: sessionIDFile, stopCommand: stopCommand)
    }

    /// The person's login shell.
    public static let shell = CommandLaneBackend(id: "shell", displayName: "Shell", command: "")

    public func launch(for lane: AgentLane, shell: String) -> TerminalLaunch {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let directory = lane.path
        guard !trimmed.isEmpty else {
            return TerminalLaunch(executable: shell, arguments: ["-l"], directory: directory)
        }
        var line = trimmed
        if passesDirectory { line += " " + ShellQuote.quote(directory) }
        if returnsToShell { line += "; exec " + ShellQuote.quote(shell) + " -l" }
        return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: directory)
    }

    public var canStop: Bool { stopCommand != nil }

    public func stop(_ lane: AgentLane) {
        guard let stopCommand else { return }
        LaneCommand.run(stopCommand(lane))
    }

    public func statusMatch(for lane: AgentLane) -> LaneStatusMatch {
        guard let statusAgent else { return .none }
        let byFolder = LaneStatusMatch.directory(lane.path, agent: statusAgent)
        guard let file = sessionIDFile?(lane),
              let raw = try? String(contentsOf: file, encoding: .utf8) else { return byFolder }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? byFolder : .session(id)
    }
}
