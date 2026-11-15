import Foundation

/// The folder of lane status records: one small JSON file per lane, replaced
/// whole on every write so a reader never sees half a record.
///
/// Writers (the hooks) and readers (the apps) agree on the folder without
/// configuration: `$AGENTSMATE_STATUS_DIR`, else
/// `$XDG_STATE_HOME/agentsmate/lanes`, else `~/.local/state/agentsmate/lanes`.
/// A GUI app does not see the shell's variables, so an app that wants another
/// folder passes it explicitly.
public struct LaneStatusDirectory: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> LaneStatusDirectory {
        if let dir = environment["AGENTSMATE_STATUS_DIR"], !dir.isEmpty {
            return LaneStatusDirectory(url: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true))
        }
        let state: URL
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            state = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            state = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state", isDirectory: true)
        }
        return LaneStatusDirectory(url: state.appendingPathComponent("agentsmate/lanes", isDirectory: true))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Record a status. An ended conversation outside a lane removes its
    /// record, so one-off sessions leave nothing behind.
    public func write(_ status: LaneStatus) throws {
        let file = url.appendingPathComponent(status.key + ".json")
        if status.state == .ended, status.lane == nil {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.encoder.encode(status).write(to: file, options: .atomic)
    }

    /// Every record, newest first. Records older than `maxAge` are skipped
    /// and removed: a lane nobody has touched in that long is not live.
    public func readAll(maxAge: TimeInterval = 7 * 24 * 3600, now: Date = Date()) -> [LaneStatus] {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        var out: [LaneStatus] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let status = try? Self.decoder.decode(LaneStatus.self, from: data) else { continue }
            if now.timeIntervalSince(status.updatedAt) > maxAge {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            out.append(status)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }
}
