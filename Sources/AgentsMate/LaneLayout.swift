import Foundation

/// How the person has arranged the lanes: named sections in their order,
/// which are collapsed, which section each lane is in, pinned lanes, the
/// manual order, and how the list is sorted. Saved as JSON in UserDefaults.
///
/// An app can give a lane a starting section (``AgentLane/section``); a
/// person's move overrides it.
public struct LaneLayout: Codable, Equatable, Sendable {
    public enum Sort: String, Codable, CaseIterable, Sendable {
        /// Sections in their order, lanes in the order the person left them.
        case manual
        /// Most recently active lane first, within each section.
        case recentFirst
        /// Most recently active lane last, within each section.
        case recentLast

        public var title: String {
            switch self {
            case .manual: "By Section"
            case .recentFirst: "Recently Active on Top"
            case .recentLast: "Recently Active at Bottom"
            }
        }
    }

    public var sections: [String] = []
    public var collapsed: Set<String> = []
    public var assignments: [String: String] = [:]
    public var pinned: Set<String> = []
    public var order: [String] = []
    public var sort: Sort = .manual
    /// Names the person gave rows, by lane id.
    public var names: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = try c.decodeIfPresent([String].self, forKey: .sections) ?? []
        collapsed = try c.decodeIfPresent(Set<String>.self, forKey: .collapsed) ?? []
        assignments = try c.decodeIfPresent([String: String].self, forKey: .assignments) ?? [:]
        pinned = try c.decodeIfPresent(Set<String>.self, forKey: .pinned) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        sort = try c.decodeIfPresent(Sort.self, forKey: .sort) ?? .manual
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
    }

    /// The name of the group pinned lanes are shown in.
    public static let pinnedSection = "Pinned"

    /// The section a lane is in: the person's choice, else the app's, else none.
    public func section(of lane: AgentLane) -> String? {
        if let assigned = assignments[lane.id] { return assigned.isEmpty ? nil : assigned }
        return lane.section
    }

    /// Every section that has a lane or that the person made, in order: the
    /// person's order first, then sections only an app named, in lane order.
    public func orderedSections(for lanes: [AgentLane]) -> [String] {
        var out = sections
        for lane in lanes {
            if let s = section(of: lane), !out.contains(s) { out.append(s) }
        }
        return out
    }

    // MARK: Editing

    public mutating func addSection(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != Self.pinnedSection, !sections.contains(name) else { return }
        sections.append(name)
    }

    public mutating func renameSection(_ old: String, to new: String, lanes: [AgentLane]) {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old, new != Self.pinnedSection else { return }
        if !sections.contains(old) { sections = orderedSections(for: lanes) }
        sections = sections.map { $0 == old ? new : $0 }
        var seen = Set<String>()
        sections = sections.filter { seen.insert($0).inserted }
        for lane in lanes where section(of: lane) == old { assignments[lane.id] = new }
        if collapsed.remove(old) != nil { collapsed.insert(new) }
    }

    /// Remove a section; its lanes go back to no section.
    public mutating func removeSection(_ name: String, lanes: [AgentLane]) {
        sections.removeAll { $0 == name }
        collapsed.remove(name)
        for lane in lanes where section(of: lane) == name { assignments[lane.id] = "" }
    }

    public mutating func moveSection(_ name: String, by offset: Int, lanes: [AgentLane]) {
        var all = orderedSections(for: lanes)
        guard let index = all.firstIndex(of: name) else { return }
        let target = min(max(index + offset, 0), all.count - 1)
        guard target != index else { return }
        all.remove(at: index)
        all.insert(name, at: target)
        sections = all
    }

    public mutating func move(_ laneID: String, to section: String?) {
        assignments[laneID] = section ?? ""
        if let section, !sections.contains(section), section != Self.pinnedSection { sections.append(section) }
    }

    public mutating func setPinned(_ laneID: String, _ pinned: Bool) {
        if pinned { self.pinned.insert(laneID) } else { self.pinned.remove(laneID) }
    }

    /// Put a lane before another (or at the end) in the manual order.
    public mutating func moveLane(_ laneID: String, before target: String?, lanes: [AgentLane]) {
        var ids = orderedIDs(lanes)
        ids.removeAll { $0 == laneID }
        if let target, let index = ids.firstIndex(of: target) {
            ids.insert(laneID, at: index)
        } else {
            ids.append(laneID)
        }
        order = ids
    }

    /// Lane ids in the manual order: the saved order, then any lane it does
    /// not know yet, in the app's order.
    func orderedIDs(_ lanes: [AgentLane]) -> [String] {
        let known = Set(lanes.map(\.id))
        var ids = order.filter { known.contains($0) }
        for lane in lanes where !ids.contains(lane.id) { ids.append(lane.id) }
        return ids
    }

    /// The lanes in display order, grouped: pinned first, then the lanes in
    /// no section, then each section. `activity` gives a lane's last activity
    /// for the recency sorts.
    public func groups(for lanes: [AgentLane], activity: (AgentLane) -> Date?) -> [LaneGroup] {
        let byID = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        var ordered = orderedIDs(lanes).compactMap { byID[$0] }
        switch sort {
        case .manual: break
        case .recentFirst, .recentLast:
            let rank = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
            ordered.sort { a, b in
                let da = activity(a) ?? .distantPast, db = activity(b) ?? .distantPast
                if da != db { return sort == .recentFirst ? da > db : da < db }
                return rank[a.id]! < rank[b.id]!
            }
        }
        var groups: [LaneGroup] = []
        let pinnedLanes = ordered.filter { pinned.contains($0.id) }
        if !pinnedLanes.isEmpty {
            groups.append(LaneGroup(section: Self.pinnedSection, lanes: pinnedLanes, isPinned: true))
        }
        let rest = ordered.filter { !pinned.contains($0.id) }
        let loose = rest.filter { section(of: $0) == nil }
        if !loose.isEmpty { groups.append(LaneGroup(section: nil, lanes: loose)) }
        for name in orderedSections(for: lanes) {
            let members = rest.filter { section(of: $0) == name }
            // A section the person made shows even while empty, so a lane
            // can be moved into it.
            if !members.isEmpty || sections.contains(name) {
                groups.append(LaneGroup(section: name, lanes: members))
            }
        }
        return groups
    }
}

/// One group of rows in the lane list.
public struct LaneGroup: Identifiable, Equatable, Sendable {
    /// Nil for lanes in no section.
    public var section: String?
    public var lanes: [AgentLane]
    public var isPinned = false

    public var id: String { isPinned ? "\u{1}pinned" : section ?? "\u{1}none" }
}
