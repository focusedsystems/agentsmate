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
    /// Where a lane's conversation is: the file its hooks named, or a Codex
    /// thread whose file is found by id.
    enum Source: Hashable, Sendable {
        case path(String)
        case codexThread(String)

        init?(_ record: LaneStatus?) {
            guard let record else { return nil }
            if let path = record.transcriptPath, !path.isEmpty {
                self = .path(path)
            } else if record.agent == "codex", let thread = record.sessionID, !thread.isEmpty {
                self = .codexThread(thread)
            } else {
                return nil
            }
        }
    }

    /// How long a Codex thread whose file was not found waits before it is
    /// looked for again.
    static let codexRetry: TimeInterval = 120

    private(set) var readers: [String: LaneTranscript] = [:]
    private(set) var codexFiles: [String: String] = [:]
    private var codexMisses: [String: Date] = [:]
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func path(for source: Source) -> String? {
        switch source {
        case .path(let path): path
        case .codexThread(let thread): codexFiles[thread]
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
