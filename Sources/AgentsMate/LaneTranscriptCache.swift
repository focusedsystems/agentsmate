import Foundation
import AgentsMateStatus

/// How often the store reads the lanes' conversation files.
enum TranscriptSchedule {
    /// While the lanes are on screen.
    static let showing: TimeInterval = 5
    /// While they are not.
    static let hidden: TimeInterval = 30

    static func interval(showing: Bool) -> TimeInterval { showing ? Self.showing : hidden }
}

/// The lanes' conversation readers, by file. A value, so a background task
/// can take it, read, and hand it back.
struct LaneTranscriptCache: Sendable {
    /// Where a lane's conversation is: the file its hooks named, a Codex
    /// thread whose file is found by id, or a Claude session (a background
    /// one, whose record names no file) found by its id and folder.
    enum Source: Hashable, Sendable {
        case path(String)
        case codexThread(String)
        case claudeSession(id: String, directory: String?)

        init?(_ record: LaneStatus?) {
            guard let record else { return nil }
            if let path = record.transcriptPath, !path.isEmpty {
                self = .path(path)
            } else if record.agent == "codex", let thread = record.sessionID, !thread.isEmpty {
                self = .codexThread(thread)
            } else if record.agent == "claude", let id = record.sessionID, LaneTranscriptCache.isSessionID(id) {
                self = .claudeSession(id: id, directory: record.directory)
            } else {
                return nil
            }
        }
    }

    /// How long a Codex thread whose file was not found waits before it is
    /// looked for again.
    static let codexRetry: TimeInterval = 120

    /// Whether `id` is a full Claude session id (a UUID), the name of its
    /// conversation file. A background session's short id is not.
    static func isSessionID(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    /// The Claude conversation file `<projects>/<encoded folder>/<id>.jsonl`:
    /// in the folder's own directory when it is there, else in whichever
    /// project directory holds it (the session may have moved folders).
    static func claudeSessionFile(id: String, directory: String?, environment: [String: String]) -> String? {
        guard isSessionID(id) else { return nil }
        let fm = FileManager.default
        let home = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let name = id + ".jsonl"
        if let directory, !directory.isEmpty {
            let encoded = String(directory.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
            let url = projects.appendingPathComponent(encoded, isDirectory: true).appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url.path }
        }
        for folder in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] where !folder.hasPrefix(".") {
            let url = projects.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url.path }
        }
        return nil
    }

    private(set) var readers: [String: LaneTranscript] = [:]
    private(set) var codexFiles: [String: String] = [:]
    private(set) var claudeFiles: [String: String] = [:]
    private var codexMisses: [String: Date] = [:]
    var environment: [String: String] = ProcessInfo.processInfo.environment
    private var codexNames: [String: String] = [:]
    private var codexIndexStamp: String?

    /// The title the person gave the lane's session, from its conversation
    /// file (Claude) or Codex's name index. Call after ``read(_:now:)``.
    mutating func title(source: Source, record: LaneStatus?) -> String? {
        if let record, record.agent == "codex", let thread = record.sessionID, !thread.isEmpty {
            refreshCodexNames()
            return codexNames[thread]
        }
        if case .codexThread(let thread) = source {
            refreshCodexNames()
            return codexNames[thread]
        }
        return path(for: source).flatMap { readers[$0]?.sessionTitle }
    }

    private mutating func refreshCodexNames() {
        let url = SessionTitle.codexIndex(environment: environment)
        let info = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\((info?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\((info?[.size] as? NSNumber) ?? 0)"
        guard stamp != codexIndexStamp else { return }
        codexIndexStamp = stamp
        codexNames = SessionTitle.codexNames(in: url)
    }

    func path(for source: Source) -> String? {
        switch source {
        case .path(let path): path
        case .codexThread(let thread): codexFiles[thread]
        case .claudeSession(let id, _): claudeFiles[id]
        }
    }

    /// Bring every source's reader up to date and return the ones that read
    /// something new, by file. Readers for files no longer asked for are
    /// dropped.
    mutating func read(_ sources: Set<Source>, now: Date = Date()) -> [String: LaneTranscript] {
        var paths: Set<String> = []
        for source in sources {
            if case .codexThread(let thread) = source, codexFiles[thread] == nil {
                if let missed = codexMisses[thread], now.timeIntervalSince(missed) < Self.codexRetry { continue }
                if let url = LaneTranscript.codexSessionFile(threadID: thread, environment: environment) {
                    codexFiles[thread] = url.path
                    codexMisses[thread] = nil
                } else {
                    codexMisses[thread] = now
                }
            }
            if case .claudeSession(let id, let directory) = source, claudeFiles[id] == nil {
                if let missed = codexMisses[id], now.timeIntervalSince(missed) < Self.codexRetry { continue }
                if let found = Self.claudeSessionFile(id: id, directory: directory, environment: environment) {
                    claudeFiles[id] = found
                    codexMisses[id] = nil
                } else {
                    codexMisses[id] = now
                }
            }
            if let path = path(for: source) { paths.insert(path) }
        }
        var changed: [String: LaneTranscript] = [:]
        var kept: [String: LaneTranscript] = [:]
        for path in paths {
            var reader = readers[path] ?? LaneTranscript(path: path)
            if readers[path] == nil || reader.hasChanged() {
                if reader.update() { changed[path] = reader }
            }
            kept[path] = reader
        }
        readers = kept
        return changed
    }
}
