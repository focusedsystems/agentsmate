import Foundation

/// One agent Reopen As offers: a title for the menu and the backend that
/// runs it, such as a persistent lane wrapper or the agent itself.
public struct LaneReopenChoice: Hashable, Sendable {
    /// What a choice is, so every app's Reopen As choices share the same
    /// keyboard shortcuts whatever they are titled or run.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        /// The agent the lane runs now, started again.
        case sameAgent
        /// Claude in a session that outlives the terminal.
        case claudeRemote
        /// Codex in a session that outlives the terminal.
        case codexRemote
        /// Claude run directly in the lane's folder.
        case claudeDirect
        /// Codex run directly in the lane's folder.
        case codexDirect

        /// The rebindable shortcut that picks this kind of choice.
        public var shortcutAction: LaneShortcutAction {
            switch self {
            case .sameAgent: .reopenSameAgent
            case .claudeRemote: .reopenClaudeRemote
            case .codexRemote: .reopenCodexRemote
            case .claudeDirect: .reopenClaudeDirect
            case .codexDirect: .reopenCodexDirect
            }
        }
    }

    public var title: String
    /// The backend the lane reopens on. Unused by ``Kind/sameAgent``, which
    /// keeps the lane's own.
    public var backendID: String
    /// Which shortcut picks this choice; nil gives it none.
    public var kind: Kind?

    public init(_ title: String, backendID: String, kind: Kind? = nil) {
        self.title = title
        self.backendID = backendID
        self.kind = kind
    }

    /// Start the lane's current agent again, in a fresh terminal.
    public static func sameAgent(_ title: String = "Same Agent") -> LaneReopenChoice {
        LaneReopenChoice(title, backendID: "", kind: .sameAgent)
    }
}
