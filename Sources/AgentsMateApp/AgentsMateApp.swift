import SwiftUI
import AgentsMateStatus

/// A dashboard of every agent on every Mac, across every agent app. It runs
/// no lanes itself: a card opens its lane in the app that has it.
@main
struct AgentsMateApp: App {
    @StateObject private var model = BoardModel()
    @State private var selection: AgentBoard.Card.ID?

    var body: some Scene {
        Window("AgentsMate", id: "board") {
            BoardView(model: model, selection: $selection)
                .frame(minWidth: 820, minHeight: 480)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { BoardCommands(model: model, selection: $selection) }
    }
}

private struct BoardCommands: Commands {
    @ObservedObject var model: BoardModel
    @Binding var selection: AgentBoard.Card.ID?
    @FocusedValue(\.stopRequest) private var stopRequest

    private var selected: AgentBoard.Card? { model.cards.first { $0.id == selection } }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .toolbar) {
            Button("Refresh") { model.refresh(remote: true) }
                .keyboardShortcut("r")
        }
        CommandMenu("Agent") {
            Button("Open in App") { if let selected { model.open(selected) } }
                .keyboardShortcut("o")
                .disabled(selected?.app == nil)
            Button("Close (Keep Running)") { if let selected { model.close(selected) } }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(selected.map(model.canClose) != true)
            Divider()
            Button("Stop Agent…") { if let selected { stopRequest?.ask(selected) } }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(selected.flatMap(model.stopTarget) == nil || stopRequest == nil)
        }
    }
}
