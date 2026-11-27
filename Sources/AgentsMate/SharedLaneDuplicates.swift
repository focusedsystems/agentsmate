import AgentsMateStatus
import Foundation

extension SharedLaneList {
    /// What a lane attaches, as one string, or nil for a lane that is always a
    /// session of its own (an overlay, a plain terminal, a row with no folder).
    ///
    /// Two lanes with the same key are two rows on one backend session: a
    /// tmux lane in a folder is named by the folder and its variant, so a second
    /// lane in the folder with no variant attaches the first one's session and
    /// both rows show that one session's title and state.
    public static func sessionKey(of lane: Lane) -> String? {
        guard lane.overlay != true else { return nil }
        let host = lane.host ?? ""
        if let name = lane.sessionName, !name.isEmpty { return "\(lane.backendID)|\(host)|name|\(name)" }
        if let id = lane.agentSessionID, !id.isEmpty { return "\(lane.backendID)|\(host)|agent|\(id)" }
        guard lane.command != nil, let directory = lane.directory else { return nil }
        let path = LaneStatusMatch.normalizedPath(expandedPath(directory))
        let variant = lane.variant.flatMap { $0.isEmpty ? nil : $0 } ?? "1"
        return "\(lane.backendID)|\(host)|dir|\(path)|\(variant)"
    }

    /// The lanes that duplicate another lane's session, each mapped to the lane
    /// that stays: the one listed first (lowest `order`, then the smaller id),
    /// which is the oldest, since a new lane goes last. Every Mac and every
    /// merge picks the same one.
    public static func duplicates(in lanes: [Lane]) -> [String: String] {
        var groups: [String: [Lane]] = [:]
        for lane in lanes {
            if let key = sessionKey(of: lane) { groups[key, default: []].append(lane) }
        }
        var dropped: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            let sorted = group.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
            for lane in sorted.dropFirst() where lane.id != sorted[0].id { dropped[lane.id] = sorted[0].id }
        }
        return dropped
    }
}
