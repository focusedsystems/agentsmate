import AppKit
import AgentsMateStatus

/// One row in the lane list: something an agent can be opened in.
///
/// The app decides what its lanes are (a folder per area, a repository, a
/// session the person started) and which backend runs each one. Nothing in
/// AgentsMate knows a path or a command of its own.
public struct AgentLane: Identifiable, Hashable, Sendable {
    /// A lane the app reaches from a button in the sidebar's filter bar and
    /// the Agent menu instead of a row in the list: the button's icon and
    /// its label, used as the tooltip, the accessibility label and the menu
    /// item. Such a lane is a lane in every other way (its terminal, status,
    /// saved selection), but it is left out of the list, the counts above
    /// it, the Dock badge, All Agents and the displayed export.
    public struct Accessory: Hashable, Sendable {
        public var icon: LaneIcon
        public var label: String
        public init(icon: LaneIcon, label: String) {
            self.icon = icon
            self.label = label
        }
        public init(symbol: String, label: String) { self.init(icon: .symbol(symbol), label: label) }
    }

    public var id: String
    public var title: String
    /// An SF Symbol name.
    public var symbol: String
    /// The lane's icon, SF Symbol or bundled. When set it wins over ``symbol``.
    public var icon: LaneIcon?
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
    /// Added to this lane's environment, after the app's and the backend's.
    public var environment: [String: String] = [:]
    /// Instructions for this lane's agent, in place of the backend's own
    /// ``CommandLaneBackend/promptFile``.
    public var promptFile: URL?
    /// Tells a persistent-lane backend this is a second (third, …) lane in
    /// the same folder, such as a duplicate, so it attaches a session of its
    /// own rather than the folder's main one.
    public var variant: String?
    /// The persistent session this row attaches, by name, when it is known
    /// exactly: a session the launch sweep found with no row, reattached or
    /// adopted. A backend that can attach by name does so instead of
    /// working the session out from the folder.
    public var sessionName: String?
    /// The agent's own short id for the persistent session this row
    /// attaches, when it is known exactly, such as a Claude Code background
    /// session's id. Several sessions can share a name, so a backend that
    /// can attach by id does so rather than by ``sessionName``.
    public var agentSessionID: String?
    /// The agent's full session id for the conversation behind
    /// ``agentSessionID``, so a stopped session can be resumed by it.
    public var agentConversationID: String?
    /// A row that must start a session of its own, such as a duplicate: its
    /// first launch starts one and binds only the id that start prints,
    /// never a running session found by name.
    public var startsNewSession = false
    /// The host the lane runs on, by its name in the hosts registry
    /// (``AgentHosts``), or nil for the default. When set, the lane's
    /// terminal gets `CLAUDE_REMOTE_HOST` and `CODEX_REMOTE_HOST` naming it,
    /// which the lane wrappers read.
    public var host: String?
    /// Set to reach this lane from a filter-bar button rather than a row;
    /// see ``Accessory``. Nil is an ordinary listed lane.
    public var accessory: Accessory?

    public init(id: String, title: String, symbol: String = "terminal", tintHex: String? = nil,
                directory: URL? = nil, backendID: String, isClosable: Bool = false,
                statusMatch: LaneStatusMatch? = nil, section: String? = nil, icon: LaneIcon? = nil) {
        self.icon = icon
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
    /// The process that resumes the lane's last conversation, or nil when
    /// the backend keeps sessions itself or cannot resume.
    func resumeLaunch(for lane: AgentLane, shell: String) -> TerminalLaunch?
    /// Whether ``stop(_:)`` ends the lane's session.
    var canStop: Bool { get }
    /// End the lane's persistent session, as closing its workspace in a
    /// terminal multiplexer would. The agent's conversation is kept, so
    /// opening the lane again resumes it.
    func stop(_ lane: AgentLane)
    /// The command that renames the agent's own session, typed into its
    /// input line when the person renames the lane, with `%@` where the new
    /// name goes, such as `/rename %@`. Nil when the agent has none.
    var renameCommand: String? { get }
    /// Whether ``stop(_:)`` can end this lane's session. Defaults to ``canStop``.
    func canStop(_ lane: AgentLane) -> Bool
    /// The name of the session a lane attaches, when the backend knows it,
    /// so the launch sweep can tell which running sessions already have a
    /// row. Defaults to ``AgentLane/sessionName``.
    func sessionName(for lane: AgentLane) -> String?
    /// The backend's own lane sessions running now, whether or not a row
    /// attaches them, for the Detached section. Only sessions this backend
    /// made or would attach belong here, never everything a multiplexer or
    /// daemon holds. Called at launch and about every ten minutes, off the
    /// main actor; keep it to one bounded helper process. Empty by default.
    func discoverSessions() async -> [DiscoveredSession]
    /// The process that attaches exactly the session named `sessionName` if
    /// it is running and does nothing else: no wrapper, no new session if it
    /// has gone. Nil when that is not the session the backend resolves for
    /// the lane (``sessionName(for:)``), or when the backend cannot attach
    /// without possibly starting one. What launch uses to open a lane by
    /// itself. Nil by default.
    func attachLaunch(for lane: AgentLane, sessionName: String, shell: String) -> TerminalLaunch?
    /// The ssh destination of the Mac this lane's agent runs on, when that
    /// is not this Mac, so an image pasted here can be sent there. Nil for
    /// a lane on this Mac. Nil by default.
    func remoteHost(for lane: AgentLane) -> String?
}

public extension LaneBackend {
    func remoteHost(for lane: AgentLane) -> String? { nil }
    func resumeLaunch(for lane: AgentLane, shell: String) -> TerminalLaunch? { nil }
    var canStop: Bool { false }
    func stop(_ lane: AgentLane) {}
    var renameCommand: String? { nil }
    func canStop(_ lane: AgentLane) -> Bool { canStop }
    func sessionName(for lane: AgentLane) -> String? { lane.sessionName }
    func discoverSessions() async -> [DiscoveredSession] { [] }
    func attachLaunch(for lane: AgentLane, sessionName: String, shell: String) -> TerminalLaunch? { nil }
}

/// Tells the person a Stop did not end the session, with what the stop said.
@MainActor
enum LaneStopReport {
    static func failed(_ title: String, _ message: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(title)” did not stop"
        alert.informativeText = message ?? "The session is still running."
        alert.runModal()
    }
}

/// Runs a command without waiting for it, for stopping a lane.
public enum LaneCommand {
    public static func run(_ arguments: [String]) {
        guard !arguments.isEmpty else { return }
        let process = Process()
        // Nobody waits on its output; the lane's row updates when it is done.
        process.qualityOfService = .background
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
    /// Instructions the app hands the agent on its command line (see
    /// ``LaunchLine``), and extra folders it may read.
    public var promptFile: URL?
    public var extraDirectories: [String] = []

    /// The wrapper's flag for a second lane in the same folder (`-n`), given
    /// the lane's ``AgentLane/variant`` before the folder. Nil means the
    /// command cannot run two lanes in one folder apart.
    public var variantFlag: String?
    /// The name a variant lane's session reports status under, when the
    /// app knows how the wrapper names it.
    public var variantStatusName: (@Sendable (AgentLane) -> String?)?

    /// The agent's command for renaming its session, with `%@` for the name.
    /// Set from ``statusAgent`` (or the command's program) to `/rename %@`
    /// for Claude Code and Codex, and nil for anything else; set it yourself
    /// to change or turn it off.
    public var renameCommand: String?

    /// How the wrapper names its tmux sessions, for finding lane sessions
    /// with no row, attaching one by name, stopping it, and lanes on another
    /// machine (``TmuxLaneSessions/host``). Nil lists nothing.
    public var tmuxSessions: TmuxLaneSessions?

    /// Whether the command's program is installed, so a picker can leave
    /// out presets this Mac cannot run.
    public var isInstalled: Bool { LaunchLine.isInstalled(command) }

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
        self.renameCommand = LaneRename.defaultCommand(statusAgent: statusAgent, command: command)
    }

    /// A wrapper that attaches a persistent tmux lane for the folder it is
    /// given, so opening the row again — here, in another terminal, or from
    /// another device — attaches the same conversation.
    public static func tmuxLane(id: String, displayName: String, command: String, statusAgent: String?,
                                sessionIDFile: (@Sendable (AgentLane) -> URL?)? = nil,
                                stopCommand: (@Sendable (AgentLane) -> [String])? = nil,
                                variantFlag: String? = nil,
                                variantStatusName: (@Sendable (AgentLane) -> String?)? = nil,
                                tmuxSessions: TmuxLaneSessions? = nil) -> CommandLaneBackend {
        var backend = CommandLaneBackend(id: id, displayName: displayName, command: command, passesDirectory: true,
                                         returnsToShell: false, statusAgent: statusAgent, keepsRunningWhenDetached: true,
                                         sessionIDFile: sessionIDFile, stopCommand: stopCommand)
        backend.variantFlag = variantFlag
        backend.variantStatusName = variantStatusName
        backend.tmuxSessions = tmuxSessions
        return backend
    }

    /// The person's login shell.
    public static let shell = CommandLaneBackend(id: "shell", displayName: "Shell", command: "")

    public func remoteHost(for lane: AgentLane) -> String? {
        tmuxSessions?.validHost
    }

    public func launch(for lane: AgentLane, shell: String) -> TerminalLaunch {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let directory = lane.path
        guard !trimmed.isEmpty else {
            return TerminalLaunch(executable: shell, arguments: ["-l"], directory: directory)
        }
        var line = passesDirectory ? trimmed
            : LaunchLine.inject(trimmed, promptFile: lane.promptFile ?? promptFile, directories: extraDirectories)
        if passesDirectory {
            if let variant = lane.variant, let variantFlag { line += " " + variantFlag + " " + ShellQuote.quote(variant) }
            line += " " + ShellQuote.quote(directory)
        }
        if let tmux = tmuxSessions {
            if tmux.host != nil {
                return remoteLaunch(tmux, lane: lane, wrapper: line, shell: shell)
            }
            if let name = lane.sessionName, TmuxLaneSessions.isValidSessionName(name) {
                // A session found running: attach exactly that one, and fall
                // back to the wrapper if it has ended since.
                let attach = tmux.localAttachLine(session: name, fallback: line)
                return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", attach], directory: directory)
            }
        }
        if returnsToShell { line += "; exec " + ShellQuote.quote(shell) + " -l" }
        return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: directory)
    }

    /// `exec tmux attach-session -t =<name>` for a lane whose tmux session
    /// on this Mac is `sessionName`, the name the lane resolves to, with no
    /// fallback: if the session has gone the terminal ends rather than run
    /// the wrapper. Nil for a lane on another host, or when `sessionName` is
    /// not the lane's own.
    public func attachLaunch(for lane: AgentLane, sessionName name: String, shell: String) -> TerminalLaunch? {
        guard keepsRunningWhenDetached, let tmux = tmuxSessions, tmux.host == nil,
              sessionName(for: lane) == name, TmuxLaneSessions.isValidSessionName(name) else { return nil }
        let line = tmux.localAttachLine(session: name, fallback: nil)
        return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: lane.path)
    }

    /// A lane on ``TmuxLaneSessions/host``: attach its session there by
    /// name when it is known, else run the wrapper there.
    private func remoteLaunch(_ tmux: TmuxLaneSessions, lane: AgentLane, wrapper: String, shell: String) -> TerminalLaunch {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let line: String
        if let name = sessionName(for: lane), let attach = tmux.remoteAttachLine(session: name) {
            line = attach
        } else if let run = tmux.sshLine(remote: wrapper) {
            line = run
        } else {
            let message = "The lane host \(tmux.host ?? "") is not an ssh destination AgentsMate can use."
            line = "printf '%s\\n' " + ShellQuote.quote(message) + "; exec " + ShellQuote.quote(shell) + " -l"
        }
        // The lane's folder is on the host, so the local terminal starts at home.
        return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: home)
    }

    public var canStop: Bool { stopCommand != nil || tmuxSessions != nil }

    public func canStop(_ lane: AgentLane) -> Bool {
        if tmuxSessions != nil, sessionName(for: lane) != nil { return true }
        return tmuxSessions?.host == nil && stopCommand != nil
    }

    /// The lane's tmux session, in the order ``statusMatch(for:)`` finds its
    /// status: the one it was found by, else for a variant what
    /// ``variantStatusName`` says, else what ``TmuxLaneSessions/sessionName``
    /// says. Nil for a variant whose two names disagree, since either could
    /// be the base lane's session.
    public func sessionName(for lane: AgentLane) -> String? {
        if let name = lane.sessionName { return name }
        let tmuxName = tmuxSessions?.sessionName?(lane)
        if lane.variant != nil {
            let variantName = variantStatusName?(lane)
            if let variantName, let tmuxName, variantName != tmuxName { return nil }
            return variantName ?? tmuxName
        }
        return tmuxName
    }

    /// The tmux sessions ``tmuxSessions`` counts as lanes, on this Mac or
    /// its host. Empty without it.
    public func discoverSessions() async -> [DiscoveredSession] {
        await tmuxSessions?.discover() ?? []
    }

    /// `claude --continue` / `codex resume --last`, falling back to the fresh
    /// command. Wrappers that keep their own sessions are not rewritten.
    public func resumeLaunch(for lane: AgentLane, shell: String) -> TerminalLaunch? {
        guard !passesDirectory, let resumed = LaneResume.command(for: command.trimmingCharacters(in: .whitespaces)) else { return nil }
        let prompt = lane.promptFile ?? promptFile
        let fresh = LaunchLine.inject(command, promptFile: prompt, directories: extraDirectories)
        let again = LaunchLine.inject(resumed, promptFile: prompt, directories: extraDirectories)
        var copy = self
        copy.promptFile = nil
        copy.extraDirectories = []
        copy.command = again + " || " + fresh
        return copy.launch(for: lane, shell: shell)
    }

    /// A session found by name, or any lane on a host, is ended by name with
    /// `tmux kill-session`; otherwise the app's ``stopCommand`` runs.
    public func stop(_ lane: AgentLane) {
        if let tmux = tmuxSessions, lane.sessionName != nil || tmux.host != nil || stopCommand == nil {
            guard let name = sessionName(for: lane), AgentSessionStop.isValidTmuxName(name) else { return }
            // The agent is asked to /exit first, so it ends its turn and
            // saves; the session is then ended and the result checked.
            let host = tmux.validHost
            let binary = host == nil ? tmux.tmux : tmux.remoteTmux
            let title = lane.title
            Task.detached {
                let outcome = await AgentSessionStop.run(.tmux(name: name), host: host, tmux: binary)
                if !outcome.stopped { await LaneStopReport.failed(title, outcome.message) }
            }
            return
        }
        guard let stopCommand else { return }
        LaneCommand.run(stopCommand(lane))
    }

    public func statusMatch(for lane: AgentLane) -> LaneStatusMatch {
        guard let statusAgent else { return .none }
        // A session found by name reports status under that name.
        if let name = lane.sessionName { return .lane(name) }
        // A variant shares the folder with the main lane, so only its own
        // session name tells them apart.
        if lane.variant != nil, let name = variantStatusName?(lane) {
            if let file = sessionIDFile?(lane), let raw = try? String(contentsOf: file, encoding: .utf8),
               case let id = raw.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                return .firstOf([.session(id), .lane(name)])
            }
            return .lane(name)
        }
        let byFolder = LaneStatusMatch.directory(lane.path, agent: statusAgent)
        guard let file = sessionIDFile?(lane),
              let raw = try? String(contentsOf: file, encoding: .utf8) else { return byFolder }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? byFolder : .session(id)
    }
}
