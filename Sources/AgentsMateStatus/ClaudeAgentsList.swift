import Foundation

/// Lane status from `claude agents --json`, which lists Claude Code's
/// background sessions (`claude --bg`) and the interactive ones already
/// running, each with its name, folder and what it is doing.
public enum ClaudeAgentsList {
    /// The `event` of every record read from the list.
    public static let event = "claude agents"
    /// The `message` of a record for a background session (`claude --bg`),
    /// as against an interactive one.
    public static let backgroundMessage = "background session"
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
    public static func parse(_ data: Data, includeInteractive: Bool = false, now: Date = Date(),
                             isResting: (String) -> Bool = { isResting(id: $0) }) -> [LaneStatus] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            if !includeInteractive, entry.kind != "background" { return nil }
            let state: LaneState
            switch entry.state ?? entry.status {
            case "working" where entry.kind == "background" && entry.id.map(isResting) == true: state = .done
            case "working", "busy": state = .running
            case "blocked": state = .waitingForInput
            case "done", "idle": state = .done
            default: return nil
            }
            return LaneStatus(agent: "claude", state: state, lane: entry.name, directory: entry.cwd,
                              sessionID: entry.sessionId ?? entry.id,
                              message: entry.kind.map { "\($0) session" },
                              event: event, updatedAt: now, agentID: entry.id)
        }
    }

    struct JobState: Decodable {
        struct InFlight: Decodable { var tasks: Int? }
        var tempo: String?
        var inFlight: InFlight?
    }

    /// Whether a background session the list calls working has in fact come
    /// to rest: its job file (`~/.claude/jobs/<id>/state.json`) says its tempo
    /// is idle with no task running. A session left with a queued input that
    /// never arrives stays "working" in the list while it waits at its prompt.
    public static func isResting(id: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), !id.isEmpty else { return false }
        let config = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let file = config.appendingPathComponent("jobs").appendingPathComponent(id).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: file), data.count < 1_000_000,
              let job = try? JSONDecoder().decode(JobState.self, from: data) else { return false }
        return job.tempo == "idle" && (job.inFlight?.tasks ?? 0) == 0
    }

    /// Run `claude agents --json` and parse it. Empty when Claude is missing
    /// or the call fails or takes longer than `timeout`.
    public static func fetch(binary: URL, includeInteractive: Bool = false, timeout: TimeInterval = 10) -> [LaneStatus] {
        guard let data = fetchData(binary: binary, timeout: timeout) else { return [] }
        return parse(data, includeInteractive: includeInteractive)
    }

    /// The raw output of `claude agents --json`, or nil when the call fails.
    public static func fetchData(binary: URL, timeout: TimeInterval = 10) -> Data? {
        let process = Process()
        process.qualityOfService = .background
        process.executableURL = binary
        process.arguments = ["agents", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global(qos: .background).asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    /// Records from a list shared by every app on the Mac.
    ///
    /// Each `claude agents --json` run starts a few dozen processes, so apps
    /// that each polled it would multiply that cost. The output is kept in
    /// one file, `claude-agents.json` beside the lane status folder. A reader
    /// uses that file while it is younger than `maxAge`; otherwise one app,
    /// holding `claude-agents.lock`, fetches and replaces it while the others
    /// keep reading the old copy. Records are stamped with the file's time,
    /// so a newer hook record still wins.
    public static func shared(cache: URL, maxAge: TimeInterval = 25, includeInteractive: Bool = false,
                              now: Date = Date(), fetch: () -> Data?) -> [LaneStatus] {
        let fm = FileManager.default
        func cached() -> (Data, Date)? {
            guard let date = (try? fm.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date,
                  let data = try? Data(contentsOf: cache) else { return nil }
            return (data, date)
        }
        func records(_ hit: (Data, Date)) -> [LaneStatus] {
            parse(hit.0, includeInteractive: includeInteractive, now: hit.1)
        }
        if let hit = cached(), now.timeIntervalSince(hit.1) < maxAge { return records(hit) }

        try? fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = cache.deletingPathExtension().appendingPathExtension("lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return cached().map(records) ?? [] }
        defer { close(fd) }
        // Another app is fetching right now: read what is there.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return cached().map(records) ?? [] }
        defer { flock(fd, LOCK_UN) }
        // It may have finished between the first look and the lock.
        if let hit = cached(), Date().timeIntervalSince(hit.1) < maxAge { return records(hit) }
        guard let data = fetch() else { return cached().map(records) ?? [] }
        try? data.write(to: cache, options: .atomic)
        return records((data, cached()?.1 ?? Date()))
    }

    /// `shared(...)` running `claude agents --json` from `binary`.
    public static func shared(binary: URL, cache: URL, maxAge: TimeInterval = 25,
                              includeInteractive: Bool = false) -> [LaneStatus] {
        shared(cache: cache, maxAge: maxAge, includeInteractive: includeInteractive) {
            fetchData(binary: binary)
        }
    }
}
