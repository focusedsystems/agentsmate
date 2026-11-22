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
        return await Task.detached(priority: .background) { () -> [LanePresence] in
            let process = Process()
            process.qualityOfService = .background
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["list-sessions", "-F", "#{session_name}\t#{session_attached}\t#{pane_current_path}"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
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
