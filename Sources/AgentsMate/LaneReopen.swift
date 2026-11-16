import Foundation

/// One agent Reopen As offers: a title for the menu and the backend that
/// runs it, such as a persistent lane wrapper or the agent itself.
public struct LaneReopenChoice: Hashable, Sendable {
    public var title: String
    public var backendID: String

    public init(_ title: String, backendID: String) {
        self.title = title
        self.backendID = backendID
    }
}
