import Foundation
import AgentsMateStatus

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
    /// Icons the person chose, by lane id, in ``LaneIcon/stringValue`` form.
    public var icons: [String: String] = [:]
    /// Colours the person chose, by lane id, as `#RRGGBB`.
    public var tints: [String: String] = [:]
    /// The person's order of the repository headings, by folder
    /// (``repositoryKey(_:)``). Empty until they move one; the app's default
    /// order applies until then.
    public var repositoryOrder: [String] = []

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
        icons = try c.decodeIfPresent([String: String].self, forKey: .icons) ?? [:]
        tints = try c.decodeIfPresent([String: String].self, forKey: .tints) ?? [:]
        repositoryOrder = try c.decodeIfPresent([String].self, forKey: .repositoryOrder) ?? []
    }

    /// Record the person's icon and colour for a lane; nil removes each.
    /// The colour is kept as `#RRGGBB`, and a value that is not one is dropped.
    public mutating func setIcon(_ icon: LaneIcon?, tint: String?, for laneID: String) {
        if let icon { icons[laneID] = icon.stringValue } else { icons.removeValue(forKey: laneID) }
        if let tint = LaneIconColors.normalised(tint) { tints[laneID] = tint } else { tints.removeValue(forKey: laneID) }
    }

    /// The name of the group pinned lanes are shown in.
    public static let pinnedSection = "Pinned"
    /// The name of the group that holds sessions running with no row.
    public static let detachedSection = "Detached"

    /// The key ``collapsed`` uses for the lanes in no section, which no
    /// section name can be.
    public static let unsectionedKey = "\u{1}none"

    /// Names a person's section cannot take, because a group of the list has them.
    static func isReserved(_ name: String) -> Bool {
        name == pinnedSection || name == detachedSection || name == unsectionedKey
    }

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
        guard !name.isEmpty, !Self.isReserved(name), !sections.contains(name) else { return }
        sections.append(name)
    }

    public mutating func renameSection(_ old: String, to new: String, lanes: [AgentLane]) {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old, !Self.isReserved(new) else { return }
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

    /// Put a section just before another, or last when `target` is nil, as a
    /// drag in the list does.
    public mutating func moveSection(_ name: String, before target: String?, lanes: [AgentLane]) {
        guard name != target else { return }
        var all = orderedSections(for: lanes)
        guard all.contains(name), target.map(all.contains) ?? true else { return }
        all.removeAll { $0 == name }
        if let target, let index = all.firstIndex(of: target) { all.insert(name, at: index) } else { all.append(name) }
        sections = all
    }

    /// Fold every group but the one with `key` (a ``LaneGroup/collapseKey``),
    /// and open that one.
    public mutating func collapseOthers(than key: String, groups: [LaneGroup]) {
        collapsed = Set(groups.map(\.collapseKey)).subtracting([key])
    }

    public mutating func move(_ laneID: String, to section: String?) {
        assignments[laneID] = section ?? ""
        if let section, !sections.contains(section), !Self.isReserved(section) { sections.append(section) }
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

    // MARK: Repository headings

    /// The key a folder's heading goes by: its path, normalized.
    public static func repositoryKey(_ path: String) -> String { LaneStatusMatch.normalizedPath(path) }

    /// The key ``collapsed`` uses for a repository heading, which no section
    /// name can be.
    public static func repositoryCollapseKey(_ key: String) -> String { "\u{2}" + key }

    /// `keys` in heading order: the person's order first, then the app's
    /// `defaultOrder`, then the rest as given. Keys in neither list keep
    /// their place relative to each other.
    public func orderedRepositories(_ keys: [String], defaultOrder: [String]) -> [String] {
        var seen = Set<String>()
        let present = Set(keys)
        var out: [String] = []
        for key in repositoryOrder + defaultOrder.map(Self.repositoryKey) + keys
        where present.contains(key) && seen.insert(key).inserted {
            out.append(key)
        }
        return out
    }

    /// Every folder the lanes work in, pinned ones too, in heading order.
    public func repositoryKeys(for lanes: [AgentLane], defaultOrder: [String]) -> [String] {
        var unpinned = self
        unpinned.pinned = []
        unpinned.sort = .manual
        var seen = Set<String>()
        let firstSeen = unpinned.groups(for: lanes) { _ in nil }.flatMap(\.lanes)
            .map { Self.repositoryKey($0.path) }.filter { seen.insert($0).inserted }
        return orderedRepositories(firstSeen, defaultOrder: defaultOrder)
    }

    /// Put a heading just before another, or last when `target` is nil;
    /// `current` is the order shown now. This becomes the person's order.
    public mutating func moveRepository(_ key: String, before target: String?, current: [String]) {
        guard key != target, current.contains(key) else { return }
        var all = current
        all.removeAll { $0 == key }
        if let target, let index = all.firstIndex(of: target) { all.insert(key, at: index) } else { all.append(key) }
        repositoryOrder = all
    }

    /// Move a heading `offset` places up (negative) or down.
    public mutating func moveRepository(_ key: String, by offset: Int, current: [String]) {
        var all = current
        guard let index = all.firstIndex(of: key) else { return }
        let target = min(max(index + offset, 0), all.count - 1)
        guard target != index else { return }
        all.remove(at: index)
        all.insert(key, at: target)
        repositoryOrder = all
    }

    /// The lanes grouped under one heading per folder: pinned first, then a
    /// heading for every folder a lane works in, in
    /// ``orderedRepositories(_:defaultOrder:)`` order. Sections no longer
    /// head anything; folders with no order of their own follow the
    /// section order and the lanes' order. A folder whose every lane is
    /// pinned has no heading.
    public func repositoryGroups(for lanes: [AgentLane], defaultOrder: [String],
                                 activity: (AgentLane) -> Date?) -> [LaneGroup] {
        let sectioned = groups(for: lanes, activity: activity)
        var groups = sectioned.filter(\.isPinned)
        var members: [String: [AgentLane]] = [:]
        for group in sectioned where !group.isPinned {
            for lane in group.lanes { members[Self.repositoryKey(lane.path), default: []].append(lane) }
        }
        for key in repositoryKeys(for: lanes, defaultOrder: defaultOrder) {
            let lanes = members[key] ?? []
            guard let head = lanes.first(where: { !$0.isClosable }) ?? lanes.first else { continue }
            groups.append(LaneGroup(section: section(of: head), lanes: lanes, repository: key,
                                    headingLaneID: head.id, heading: head.isClosable ? (head.path as NSString).lastPathComponent : head.title))
        }
        return groups
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
    /// The Detached group: sessions the launch sweep found with no row.
    public var isDetached = false
    /// A repository heading: the folder (``LaneLayout/repositoryKey(_:)``)
    /// whose lanes and found sessions it holds. Nil for a section.
    public var repository: String?
    /// The lane whose icon and name the repository heading shows.
    public var headingLaneID: String?
    /// The repository heading's name when no lane names it.
    public var heading: String?

    public init(section: String?, lanes: [AgentLane], isPinned: Bool = false, isDetached: Bool = false,
                repository: String? = nil, headingLaneID: String? = nil, heading: String? = nil) {
        self.section = section
        self.lanes = lanes
        self.isPinned = isPinned
        self.isDetached = isDetached
        self.repository = repository
        self.headingLaneID = headingLaneID
        self.heading = heading
    }

    public var id: String {
        if let repository { return "\u{2}" + repository }
        return isPinned ? "\u{1}pinned" : isDetached ? "\u{1}detached" : section ?? "\u{1}none"
    }

    /// What ``LaneLayout/collapsed`` holds while this group is folded.
    public var collapseKey: String {
        if let repository { return LaneLayout.repositoryCollapseKey(repository) }
        return isPinned ? LaneLayout.pinnedSection : isDetached ? LaneLayout.detachedSection
            : section ?? LaneLayout.unsectionedKey
    }

    /// The name its header shows; nil for the lanes in no section, which
    /// show the list's title.
    public var title: String? {
        if repository != nil { return heading }
        return isPinned ? LaneLayout.pinnedSection : isDetached ? LaneLayout.detachedSection : section
    }
}
