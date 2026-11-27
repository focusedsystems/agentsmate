import SwiftUI
import AgentsMateDevelopment
import AgentsMateStatus

/// A dashboard of every agent on every Mac, across every agent app. It runs
/// no lanes itself: a card opens its lane in the app that has it.
@main
struct AgentsMateApp: App {
    @StateObject private var model = BoardModel()
    @StateObject private var hub = DevelopmentHub()
    @StateObject private var ask = AskModel()
    @State private var selection: AgentBoard.Card.ID?
    @AppStorage("selectedTab") private var tabRaw = AgentsTab.agents.rawValue

    var body: some Scene {
        Window("AgentsMate", id: "board") {
            RootView(model: model, ask: ask, hub: hub, selection: $selection, tabRaw: $tabRaw)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { BoardCommands(model: model, ask: ask, hub: hub, selection: $selection, tabRaw: $tabRaw) }
    }
}

/// The window: the toolbar's tab control over the board or one of DevMate's
/// views. The window keeps its title for Mission Control and the Window menu,
/// but shows none, since the menu bar already names the app.
private struct RootView: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var ask: AskModel
    @ObservedObject var hub: DevelopmentHub
    @Binding var selection: AgentBoard.Card.ID?
    @Binding var tabRaw: String

    private var tab: AgentsTab { AgentsTab(saved: tabRaw) }

    var body: some View {
        Group {
            if tab == .agents {
                BoardView(model: model, ask: ask, selection: $selection)
            } else {
                DevelopmentTabView(hub: hub, tab: tab)
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tabRaw) {
                    ForEach(AgentsTab.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .help("Agents, or the pull requests, pipelines, commits, repos and projects of every app (⌘1 to ⌘6)")
            }
        }
        .onAppear { model.start() }
        .onOpenURL { url in
            guard let (kind, web) = AgentsMateLink.parse(url) else { return }
            _ = hub.focus(kind, on: web)
            tabRaw = AgentsTab(link: kind).rawValue
        }
    }
}

private struct BoardCommands: Commands {
    @ObservedObject var model: BoardModel
    @ObservedObject var ask: AskModel
    let hub: DevelopmentHub
    @Binding var selection: AgentBoard.Card.ID?
    @Binding var tabRaw: String
    @FocusedValue(\.stopRequest) private var stopRequest
    @AppStorage("hostFilter") private var hostFilter = ""
    @AppStorage("agentFilter") private var agentFilter = ""

    private var selected: AgentBoard.Card? { model.cards.first { $0.id == selection } }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .toolbar) {
            ForEach(AgentsTab.allCases) { tab in
                Toggle(tab.title, isOn: Binding(get: { tabRaw == tab.rawValue }, set: { _ in tabRaw = tab.rawValue }))
                    .keyboardShortcut(KeyEquivalent(tab.shortcutKey), modifiers: .command)
            }
            Divider()
        }
        CommandGroup(after: .toolbar) {
            Button("Reload Now") {
                if AgentsTab(saved: tabRaw) == .agents { model.refresh(remote: true) } else { hub.refresh() }
            }
            .keyboardShortcut("r")
            Divider()
            Picker("Mac", selection: $hostFilter) {
                Text("All Macs").tag("")
                ForEach([model.localHost] + model.remoteHosts, id: \.self) { Text($0).tag($0) }
            }
            Picker("Agent", selection: $agentFilter) {
                Text("All Agents").tag("")
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
            }
        }
        CommandMenu("Agent") {
            Button("Ask About Lanes…") {
                tabRaw = AgentsTab.agents.rawValue
                ask.focus()
            }
            .keyboardShortcut("k")
            Divider()
            Button("Open in App") { if let selected { model.open(selected) } }
                .keyboardShortcut("o")
                .disabled(selected.map { $0.app != nil || model.attachCommand($0) != nil } != true)
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
