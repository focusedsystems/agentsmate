import Foundation
import AgentsMateStatus

/// A persistent session that exists right now, and how many terminals have
/// it open. A session with none is an orphan: it runs and costs resources,
/// but nothing shows it.
public struct LanePresence: Equatable, Sendable {
    /// The session's name, as a backend's status match names it.
    public var name: String
    public var directory: String?
    public var attachedClients: Int
    /// Whether a Claude or Codex process runs in the session's pane; nil
    /// when that was not checked. A pane with only a shell is no running agent.
    public var hasAgent: Bool?
    /// The process id of the session's active pane, when listed.
    public var panePID: Int?

    public init(name: String, directory: String?, attachedClients: Int, hasAgent: Bool? = nil, panePID: Int? = nil) {
        self.hasAgent = hasAgent
        self.panePID = panePID
        self.name = name
        self.directory = directory
        self.attachedClients = attachedClients
    }
}

/// Somewhere that lists running sessions, polled on the status feed's timer.
public protocol LanePresenceSource: Sendable {
    func sessions() async -> [LanePresence]
}

/// Every tmux session on this Mac, with its attached-client count and the
/// working directory of its active pane.
public struct TmuxPresenceSource: LanePresenceSource {
    public let tmux: String

    /// `tmux` is a path, or a name found in the usual install folders.
    public init(tmux: String = "tmux") {
        if tmux.contains("/") {
            self.tmux = tmux
        } else {
            let found = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
                .map { $0 + "/" + tmux }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            self.tmux = found ?? tmux
        }
    }

    public func sessions() async -> [LanePresence] {
        let tmux = tmux
        return await Task.detached(priority: .background) { () -> [LanePresence] in
            let process = Process()
            process.qualityOfService = .background
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["list-sessions", "-F", "#{session_name}\t#{session_attached}\t#{pane_current_path}\t#{pane_pid}"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let listed = Self.parse(String(decoding: data, as: UTF8.self))
            let table = AgentProcesses.table()
            return listed.map { entry in
                var entry = entry
                if let pid = entry.panePID, !table.isEmpty { entry.hasAgent = AgentProcesses.hasAgent(under: pid, in: table) }
                return entry
            }
        }.value
    }

    static func parse(_ output: String) -> [LanePresence] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let attached = Int(fields[1]) else { return nil }
            return LanePresence(name: fields[0], directory: fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil,
                                attachedClients: attached, panePID: fields.count > 3 ? Int(fields[3]) : nil)
        }
    }
}

extension Array where Element == LanePresence {
    /// The session behind a lane: by name when the lane is matched by name,
    /// else the one whose folder is the lane's. A lane that reports no
    /// status (``LaneStatusMatch/none``) has none.
    func find(for lane: AgentLane, match: LaneStatusMatch) -> LanePresence? {
        locate(for: lane, match: match)?.presence
    }

    /// ``find(for:match:)``, saying whether the session was matched by its
    /// tmux name, which names one lane's session, rather than by a folder
    /// any session could be working in.
    func locate(for lane: AgentLane, match: LaneStatusMatch) -> (presence: LanePresence, byName: Bool)? {
        switch match {
        case .none:
            return nil
        case .lane(let name):
            return first { $0.name == name }.map { ($0, true) }
        case .firstOf(let matches):
            for match in matches { if let found = locate(for: lane, match: match) { return found } }
            return nil
        case .directory, .session:
            let want = LaneStatusMatch.normalizedPath(lane.path)
            return first { $0.directory.map(LaneStatusMatch.normalizedPath) == want }.map { ($0, false) }
        }
    }
}

/// Whether a Claude or Codex process runs under a tmux pane, from the process
/// table rather than anything the terminal printed.
enum AgentProcesses {
    struct Entry: Equatable { var pid: Int; var parent: Int; var command: String }

    /// Whether a process's command line is Claude or Codex: its program is
    /// named so, or lives in a folder of that name (Claude's versioned binary).
    static func isAgent(command: String) -> Bool {
        let program = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        let base = (program as NSString).lastPathComponent.lowercased()
        if base == "claude" || base == "codex" { return true }
        let parts = program.lowercased().split(separator: "/")
        return parts.contains("claude") || parts.contains("codex")
    }

    static func hasAgent(under root: Int, in table: [Entry]) -> Bool {
        var wanted: Set<Int> = [root]
        var grew = true
        while grew {
            grew = false
            for entry in table where wanted.contains(entry.parent) && wanted.insert(entry.pid).inserted { grew = true }
        }
        return table.contains { wanted.contains($0.pid) && isAgent(command: $0.command) }
    }

    static func parse(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let parent = Int(parts[1]) else { return nil }
            return Entry(pid: pid, parent: parent, command: String(parts[2]))
        }
    }

    static func table() -> [Entry] {
        let process = Process()
        process.qualityOfService = .background
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }
}
