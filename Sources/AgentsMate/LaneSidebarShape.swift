import SwiftUI

/// Where a session found for a lane (a parallel session, such as a second
/// conversation in the same folder) goes in the sidebar.
public enum ParallelSessionPlacement: String, CaseIterable, Sendable, Identifiable {
    /// A row of its own, as top-level as its lane's, just after it.
    case topLevel
    /// Indented under its lane's row.
    case nested

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topLevel: "Top-Level Rows, Like Their Lane"
        case .nested: "Nested Under Their Lane"
        }
    }
}

/// The sidebar's shape: the app's defaults
/// (``AgentLaneStore/Configuration``), with the person's choices from
/// ``AgentSidebarSettingsSection`` on top. Views read these through
/// `@AppStorage` on the same keys, so a change applies at once.
extension AgentLaneStore {
    var sidebarDefaults: (headings: Bool, icons: Bool, parallel: ParallelSessionPlacement, pullRequests: Bool) {
        (configuration.showsSectionHeadings, configuration.showsLaneIcons, configuration.parallelSessions,
         configuration.showsPullRequestPills)
    }

    /// The lane a found session belongs to, when it was placed under one.
    func parallelOwner(of laneID: AgentLane.ID) -> AgentLaneSession? {
        guard isDetached(laneID), let owner = detachedOwners[laneID] else { return nil }
        return sessions[owner]
    }

    /// The icon a row draws: a parallel session with no icon of its own
    /// takes its lane's, so the two rows look alike and only their titles
    /// tell them apart.
    func rowIcon(for session: AgentLaneSession) -> (icon: LaneIcon, tintHex: String?) {
        if session.customIcon == nil, let owner = parallelOwner(of: session.id) {
            return (owner.icon, session.customTintHex ?? owner.tintHex)
        }
        return (session.icon, session.tintHex)
    }
}

/// A Sidebar section for an app's Agent settings: section headings, row
/// icons and where parallel sessions go. Each starts at the app's default
/// and the person's choice is saved under the app's ``AgentsModeKeys``.
/// Put it in a grouped `Form`; ``AgentLaneSettingsSection`` includes it.
public struct AgentSidebarSettingsSection: View {
    let store: AgentLaneStore

    public init(store: AgentLaneStore) { self.store = store }

    public var body: some View {
        Section {
            AgentSidebarSettingsControls(store: store)
        } header: {
            Text("Sidebar")
        }
    }
}

/// The sidebar controls on their own, for an app whose Agent settings are
/// not a grouped `Form`.
public struct AgentSidebarSettingsControls: View {
    @AppStorage private var headings: Bool
    @AppStorage private var icons: Bool
    @AppStorage private var parallel: String
    @AppStorage private var pullRequests: Bool

    public init(store: AgentLaneStore) {
        let keys = store.keys
        let defaults = store.sidebarDefaults
        _headings = AppStorage(wrappedValue: defaults.headings, keys.showsSectionHeadings)
        _icons = AppStorage(wrappedValue: defaults.icons, keys.showsLaneIcons)
        _parallel = AppStorage(wrappedValue: defaults.parallel.rawValue, keys.parallelSessions)
        _pullRequests = AppStorage(wrappedValue: defaults.pullRequests, keys.showsPullRequestPills)
    }

    public var body: some View {
        Toggle("Show section headings", isOn: $headings)
            .help("Head the list with its sections. Off, every row is in one list; Pinned and Detached keep their headings.")
        Toggle("Show lane icons", isOn: $icons)
            .help("Draw each row's icon. Off, a row shows its status dot alone.")
        Toggle("Show pull request pills", isOn: $pullRequests)
            .help("Draw a pill for each pull request on a row and on an All Agents card. Off, pull requests are still in the row's menu and hover.")
        Picker("Parallel sessions", selection: $parallel) {
            ForEach(ParallelSessionPlacement.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .help("Where another session in a lane's folder goes: a row of its own like the lane's, or indented under it. Either way it keeps its own title and the lane's icon.")
    }
}
