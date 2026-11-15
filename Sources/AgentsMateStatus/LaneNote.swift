import Foundation

/// What a script running in a lane says about its own work: a line of
/// status text, how far along it is, and the last few log lines. Written by
/// `agentsmate-status note …`; shown on the lane's row.
public struct LaneNote: Codable, Equatable, Sendable {
    /// The lane: its tmux session name or the id the app gave it.
    public var lane: String
    public var text: String?
    /// 0–1, or nil for no progress bar.
    public var progress: Double?
    /// The newest last, at most ``maxLog`` lines.
    public var log: [String]
    public var updatedAt: Date

    public static let maxLog = 20

    public init(lane: String, text: String? = nil, progress: Double? = nil, log: [String] = [], updatedAt: Date = Date()) {
        self.lane = lane
        self.text = text
        self.progress = progress
        self.log = log
        self.updatedAt = updatedAt
    }

    /// Text tidied for a row: control characters stripped, cut to 200.
    static func clean(_ s: String) -> String {
        let flat = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return String(flat.trimmingCharacters(in: .whitespaces).prefix(200))
    }
}

extension LaneStatusDirectory {
    /// Notes live beside the status records, one file per lane.
    public var notesURL: URL { url.deletingLastPathComponent().appendingPathComponent("notes", isDirectory: true) }

    private func noteFile(_ lane: String) -> URL {
        notesURL.appendingPathComponent(LaneStatus.slug(lane) + ".json")
    }

    public func readNote(lane: String) -> LaneNote? {
        guard let data = try? Data(contentsOf: noteFile(lane)) else { return nil }
        return try? Self.decoder.decode(LaneNote.self, from: data)
    }

    /// Change a lane's note: set its text or progress, add a log line, or
    /// clear it. Nil arguments leave that part as it was.
    public func updateNote(lane: String, text: String? = nil, progress: Double? = nil, log line: String? = nil,
                           clear: Bool = false, now: Date = Date()) throws {
        let file = noteFile(lane)
        if clear {
            try? FileManager.default.removeItem(at: file)
            return
        }
        var note = readNote(lane: lane) ?? LaneNote(lane: lane)
        if let text { note.text = text.isEmpty ? nil : LaneNote.clean(text) }
        if let progress { note.progress = progress < 0 ? nil : min(progress, 1) }
        if let line {
            note.log.append(LaneNote.clean(line))
            note.log = Array(note.log.suffix(LaneNote.maxLog))
        }
        note.updatedAt = now
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
        try Self.encoder.encode(note).write(to: file, options: .atomic)
    }

    /// Every note, dropping any older than `maxAge`.
    public func readNotes(maxAge: TimeInterval = 24 * 3600, now: Date = Date()) -> [LaneNote] {
        let files = (try? FileManager.default.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                  let note = try? Self.decoder.decode(LaneNote.self, from: data) else { return nil }
            if now.timeIntervalSince(note.updatedAt) > maxAge {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return note
        }
    }
}
