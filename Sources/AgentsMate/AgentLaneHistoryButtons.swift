import SwiftUI

/// Back and Forward through the lanes visited, for an app's toolbar:
///
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .navigation) { AgentLaneHistoryButtons(store: store) }
/// }
/// ```
///
/// They follow the same history as the Agent menu's Back and Forward
/// (``AgentLaneStore/goBack()``, ``AgentLaneStore/goForward()``) and show
/// the person's shortcuts for them in their help tags. The menu items keep
/// the keyboard shortcuts, so the buttons carry none of their own.
public struct AgentLaneHistoryButtons: View {
    @ObservedObject var store: AgentLaneStore
    /// Called before moving, so the app can bring its lanes on screen.
    let reveal: () -> Void

    public init(store: AgentLaneStore, reveal: @escaping () -> Void = {}) {
        self.store = store
        self.reveal = reveal
    }

    public var body: some View {
        ControlGroup {
            Button {
                reveal()
                store.goBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(!store.canGoBack)
            .help(help("Back to the previous lane", .back))
            Button {
                reveal()
                store.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .disabled(!store.canGoForward)
            .help(help("Forward to the next lane", .forward))
        }
        .controlGroupStyle(.navigation)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lane History")
    }

    private func help(_ text: String, _ action: LaneShortcutAction) -> String {
        guard let key = store.shortcuts.binding(for: action)?.display else { return text }
        return "\(text) (\(key))"
    }
}
