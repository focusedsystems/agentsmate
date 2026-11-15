import Foundation

/// How an app finds the record that belongs to one of its lanes.
public enum LaneStatusMatch: Hashable, Sendable {
    /// The record whose tmux session has this name.
    case lane(String)
    /// The newest lane record started in this folder, optionally by one agent.
    case directory(String, agent: String?)
    /// The record of one agent session, by its id or the start of it.
    case session(String)
    /// The first of these that finds a record.
    case firstOf([LaneStatusMatch])
    /// The lane reports no status (a plain shell, say).
    case none

    /// The newest record in `records` that belongs to this lane. Records
    /// outside any tmux session match only by name, so a conversation
    /// someone runs by hand in the same folder never colours a lane.
    public func find(in records: [LaneStatus]) -> LaneStatus? {
        switch self {
        case .none:
            return nil
        case .session(let id):
            guard !id.isEmpty else { return nil }
            return records.filter { $0.sessionID.map { $0 == id || $0.hasPrefix(id) } ?? false }
                .max { $0.updatedAt < $1.updatedAt }
        case .firstOf(let matches):
            for match in matches { if let found = match.find(in: records) { return found } }
            return nil
        case .lane(let name):
            return records.filter { $0.lane == name }.max { $0.updatedAt < $1.updatedAt }
        case .directory(let path, let agent):
            let want = Self.normalize(path)
            return records.filter { record in
                guard record.lane != nil, let dir = record.directory else { return false }
                if let agent, record.agent != agent { return false }
                return Self.normalize(dir) == want
            }.max { $0.updatedAt < $1.updatedAt }
        }
    }

    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var out = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }
}
