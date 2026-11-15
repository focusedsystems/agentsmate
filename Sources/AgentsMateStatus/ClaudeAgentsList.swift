import Foundation

/// Lane status from `claude agents --json`, which lists Claude Code's
/// background sessions (`claude --bg`) and the interactive ones already
/// running, each with its name, folder and what it is doing.
public enum ClaudeAgentsList {
    /// The `event` of every record read from the list.
    public static let event = "claude agents"
    struct Entry: Decodable {
        var id: String?
        var sessionId: String?
        var name: String?
        var cwd: String?
        var kind: String?
        /// Interactive sessions: `idle` or `busy`.
        var status: String?
        /// Background sessions: `working`, `blocked` or `done`.
        var state: String?
    }

    /// Records for the listed sessions; the session's name is its lane.
    /// Interactive sessions are left out unless asked for: those running in
    /// tmux lanes already report through hooks, and a poll would outdate a
    /// permission prompt a hook just recorded.
    public static func parse(_ data: Data, includeInteractive: Bool = false, now: Date = Date()) -> [LaneStatus] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            if !includeInteractive, entry.kind != "background" { return nil }
            let state: LaneState
            switch entry.state ?? entry.status {
            case "working", "busy": state = .running
            case "blocked": state = .waitingForInput
            case "done", "idle": state = .done
            default: return nil
            }
            return LaneStatus(agent: "claude", state: state, lane: entry.name, directory: entry.cwd,
                              sessionID: entry.sessionId ?? entry.id,
                              message: entry.kind.map { "\($0) session" },
                              event: event, updatedAt: now)
        }
    }

    /// Run `claude agents --json` and parse it. Empty when Claude is missing
    /// or the call fails or takes longer than `timeout`.
    public static func fetch(binary: URL, timeout: TimeInterval = 10) -> [LaneStatus] {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["agents", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return parse(data)
    }
}
