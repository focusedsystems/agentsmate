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

    public init(name: String, directory: String?, attachedClients: Int) {
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
        return await Task.detached { () -> [LanePresence] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["list-sessions", "-F", "#{session_name}\t#{session_attached}\t#{pane_current_path}"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Self.parse(String(decoding: data, as: UTF8.self))
        }.value
    }

    static func parse(_ output: String) -> [LanePresence] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let attached = Int(fields[1]) else { return nil }
            return LanePresence(name: fields[0], directory: fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil,
                                attachedClients: attached)
        }
    }
}

extension Array where Element == LanePresence {
    /// The session behind a lane: by name when the lane is matched by name,
    /// else the one whose folder is the lane's.
    func find(for lane: AgentLane, match: LaneStatusMatch) -> LanePresence? {
        if case .lane(let name) = match { return first { $0.name == name } }
        let want = LaneStatusMatch.normalizedPath(lane.path)
        return first { $0.directory.map(LaneStatusMatch.normalizedPath) == want }
    }
}
