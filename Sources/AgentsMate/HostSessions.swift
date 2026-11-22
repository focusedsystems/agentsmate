import Foundation
import AgentsMateStatus

/// How the store reads what each lane host has running, so launch can
/// reattach a lane whose session runs on another Mac. Off unless an app sets
/// ``AgentLaneStore/Configuration/hostSessions``.
///
/// Every host in the hosts registry (``AgentHosts``) with role hub or lane is
/// asked once at launch: this Mac by running the commands, any other over
/// read-only `ssh` in batch mode (never prompting) with a connect timeout. A
/// host that does not answer is unknown, never a host whose sessions ended.
public struct HostSessionsConfiguration: Sendable {
    /// The `claude` command on each host, run in its login shell.
    public var claude: String
    /// The `tmux` command on each host, run in its login shell.
    public var tmux: String
    /// The login shell the commands run in on each host.
    public var shell: String
    /// A `sh` command run on each host that prints one `<key>\t<id>` line per
    /// lane, tying a lane (by ``bindingKey``) to the Claude background
    /// session that is its own, by that session's short id. A lane bound
    /// this way is attached by id, never by name. Nil when the app has none.
    public var bindingsCommand: String?
    /// The key a lane is listed under in ``bindingsCommand``'s output; its id
    /// by default.
    public var bindingKey: @Sendable (AgentLane) -> String
    public var ssh: String
    public var connectTimeout: Int
    /// How long one host may take to answer before it counts as unknown.
    public var timeout: TimeInterval

    public init(claude: String = "claude", tmux: String = "tmux", shell: String = "/bin/zsh",
                bindingsCommand: String? = nil,
                bindingKey: @escaping @Sendable (AgentLane) -> String = { $0.id },
                ssh: String = "/usr/bin/ssh", connectTimeout: Int = 5, timeout: TimeInterval = 15) {
        self.claude = claude
        self.tmux = tmux
        self.shell = shell
        self.bindingsCommand = bindingsCommand
        self.bindingKey = bindingKey
        self.ssh = ssh
        self.connectTimeout = connectTimeout
        self.timeout = timeout
    }
}

/// What one host had running when it was asked.
public struct HostSessionListing: Equatable, Sendable {
    /// Claude Code's background sessions there, each with its short id
    /// (``LaneStatus/agentID``).
    public var claude: [LaneStatus]
    /// The names of the tmux sessions there.
    public var tmux: [String]
    /// Lane key to Claude session short id, from
    /// ``HostSessionsConfiguration/bindingsCommand``.
    public var bindings: [String: String]

    public init(claude: [LaneStatus] = [], tmux: [String] = [], bindings: [String: String] = [:]) {
        self.claude = claude
        self.tmux = tmux
        self.bindings = bindings
    }
}

/// The one session launch attaches for a lane, found exactly: by a Claude
/// session's short id, or a tmux session's whole name, on the lane's host.
public enum HostAttachTarget: Equatable, Sendable {
    case claude(id: String, host: String?)
    case tmux(name: String, host: String?)
}

enum HostSessions {
    static let tmuxMark = "<<agentsmate:tmux>>"
    static let bindingsMark = "<<agentsmate:bindings>>"
    static let endMark = "<<agentsmate:end>>"

    /// The script each host runs: three read-only listings between marks.
    /// Each listing may fail on its own and is then empty; the end mark is
    /// what says the host answered.
    static func script(_ config: HostSessionsConfiguration) -> String {
        var lines = [ShellQuote.quote(config.claude) + " agents --json 2>/dev/null",
                     "echo; echo " + ShellQuote.quote(tmuxMark),
                     ShellQuote.quote(config.tmux) + " list-sessions -F '#{session_name}' 2>/dev/null",
                     "echo " + ShellQuote.quote(bindingsMark)]
        // In sh, so a login shell's own rules (zsh ending the whole script
        // on a glob that matches nothing) never cut the listing short.
        if let bindings = config.bindingsCommand, !bindings.isEmpty {
            lines.append("/bin/sh -c " + ShellQuote.quote(bindings) + " 2>/dev/null")
        }
        lines.append("echo " + ShellQuote.quote(endMark))
        return lines.joined(separator: "; ")
    }

    /// The process that lists `host`'s sessions: the script in a login shell
    /// here when `host` is nil, else the same over ssh in batch mode. Nil
    /// for a host name ssh cannot be handed safely.
    static func command(host: String?, config: HostSessionsConfiguration) -> (executable: String, arguments: [String])? {
        let script = script(config)
        guard let host else { return (config.shell, ["-lc", script]) }
        guard AgentHosts.isValidName(host) else { return nil }
        let remote = ShellQuote.quote(config.shell) + " -lc " + ShellQuote.quote(script)
        return (config.ssh, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(config.connectTimeout)",
                             "-T", "--", host, remote])
    }

    /// The listing in a host's output, or nil when the host did not answer
    /// to the end.
    static func parse(_ output: String) -> HostSessionListing? {
        guard let end = output.range(of: endMark),
              let tmux = output.range(of: tmuxMark), tmux.upperBound <= end.lowerBound,
              let bindings = output.range(of: bindingsMark), tmux.upperBound <= bindings.lowerBound,
              bindings.upperBound <= end.lowerBound else { return nil }
        let claudeText = output[..<tmux.lowerBound]
        let tmuxText = output[tmux.upperBound..<bindings.lowerBound]
        let bindingsText = output[bindings.upperBound..<end.lowerBound]
        let claude = ClaudeAgentsList.parse(Data(claudeText.utf8))
        let names = tmuxText.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        var bound: [String: String] = [:]
        for line in bindingsText.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 2, !fields[0].isEmpty, isValidAgentID(fields[1]) else { continue }
            bound[fields[0]] = fields[1]
        }
        return HostSessionListing(claude: claude, tmux: names, bindings: bound)
    }

    /// Ask one host. Nil means unknown: ssh failed, timed out, or the
    /// output did not reach the end mark.
    static func list(host: String?, config: HostSessionsConfiguration) async -> HostSessionListing? {
        guard let command = command(host: host, config: config) else { return nil }
        let timeout = config.timeout
        return await Task.detached(priority: .utility) { () -> HostSessionListing? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// A Claude short id: letters, digits and dashes only.
    static func isValidAgentID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix("-")
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The one session launch may attach for `lane`, from what its host had
    /// running. A lane bound to a Claude session attaches it by short id
    /// while the host still lists that id; a Claude background lane
    /// attaches the one session whose name is exactly its own; otherwise a
    /// tmux session with exactly the lane's session name. Nil when none of
    /// these holds; nothing is matched by folder or by part of a name.
    static func target(for lane: AgentLane, backend: any LaneBackend, listing: HostSessionListing,
                       config: HostSessionsConfiguration, remoteHost: String?) -> HostAttachTarget? {
        guard backend.keepsRunningWhenDetached else { return nil }
        let live = listing.claude.filter { $0.state != .ended && $0.agentID.map(isValidAgentID) == true }
        if let bound = listing.bindings[config.bindingKey(lane)] {
            let found = live.filter { $0.agentID == bound }
            if found.count == 1, let id = found[0].agentID { return .claude(id: id, host: remoteHost) }
            // Bound to a session the host no longer lists: nothing to attach.
            return nil
        }
        let name = backend.sessionName(for: lane)
        if backend is ClaudeBackgroundLaneBackend, let name {
            let found = live.filter { $0.lane == name }
            if found.count == 1, let id = found[0].agentID { return .claude(id: id, host: remoteHost) }
            return nil
        }
        if let name, TmuxLaneSessions.isValidSessionName(name), listing.tmux.contains(name) {
            return .tmux(name: name, host: remoteHost)
        }
        return nil
    }

    /// The terminal process that attaches `target` and does nothing else:
    /// no fallback that starts a session. If it fails, the terminal ends and
    /// the row offers Reattach.
    static func launch(_ target: HostAttachTarget, lane: AgentLane, shell: String,
                       config: HostSessionsConfiguration) -> TerminalLaunch? {
        let attach: String
        let host: String?
        switch target {
        case .claude(let id, let on):
            guard isValidAgentID(id) else { return nil }
            attach = ShellQuote.quote(config.claude) + " attach " + ShellQuote.quote(id)
            host = on
        case .tmux(let name, let on):
            guard TmuxLaneSessions.isValidSessionName(name) else { return nil }
            attach = ShellQuote.quote(config.tmux) + " attach-session -t " + ShellQuote.quote("=" + name)
            host = on
        }
        guard let host else {
            return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", "exec " + attach], directory: lane.path)
        }
        guard AgentHosts.isValidName(host) else { return nil }
        let remote = ShellQuote.quote(config.shell) + " -lc " + ShellQuote.quote("exec " + attach)
        let line = "exec " + ShellQuote.quote(config.ssh) + " -t -o " + ShellQuote.quote("ConnectTimeout=\(config.connectTimeout)")
            + " -- " + ShellQuote.quote(host) + " " + ShellQuote.quote(remote)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return TerminalLaunch(executable: shell, arguments: ["-l", "-i", "-c", line], directory: home)
    }
}
