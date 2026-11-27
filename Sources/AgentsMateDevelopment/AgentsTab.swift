import AgentsMateStatus
import DevMateUI

/// The window's views, in the order of the toolbar control and ⌘1 to ⌘6.
public enum AgentsTab: String, CaseIterable, Identifiable, Sendable {
    case agents, pulls, pipelines, commits, repos, projects

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .agents: "Agents"
        case .pulls: "Pulls"
        case .pipelines: "Pipelines"
        case .commits: "Commits"
        case .repos: "Repos"
        case .projects: "Projects"
        }
    }

    /// The digit of the ⌘ shortcut.
    public var shortcutKey: Character { Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)) }

    /// The saved choice, or Agents when nothing valid was saved.
    public init(saved: String?) { self = saved.flatMap(Self.init(rawValue:)) ?? .agents }

    /// The view an `agentsmate://` link opens.
    public init(link kind: AgentsMateLink.Kind) {
        switch kind {
        case .pull: self = .pulls
        case .pipeline: self = .pipelines
        case .commit: self = .commits
        }
    }

    /// The Development view this tab shows; Agents and Projects have none.
    @MainActor
    var segment: DevelopmentModel.Segment? {
        switch self {
        case .pulls: .pullRequests
        case .pipelines: .pipelines
        case .commits: .commits
        case .repos: .repos
        case .agents, .projects: nil
        }
    }
}
