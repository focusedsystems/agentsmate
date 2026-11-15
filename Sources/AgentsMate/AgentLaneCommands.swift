import SwiftUI
import AppKit

/// The lanes' menu: every lane on ⌘1–⌘9 (when the app gives it those keys),
/// moving between them, and attaching, detaching or clearing the selected
/// one. Every command here is also on the row's contextual menu or a
/// terminal shortcut, so the menu bar is where people find them.
public struct AgentLaneCommands: Commands {
    @ObservedObject var store: AgentLaneStore
    let menuTitle: String
    let labels: AgentsModeLabels
    let numberShortcuts: Bool
    let emptyText: String
    /// Bigger Text, Smaller Text and Actual Size on ⌘+, ⌘- and ⌘0. Off for
    /// an app whose View menu already owns those keys.
    let fontCommands: Bool
    /// Called before a menu command acts, so the app can bring its lanes on screen.
    let reveal: () -> Void

    public init(store: AgentLaneStore, menuTitle: String = "Agent", labels: AgentsModeLabels = .init(),
                numberShortcuts: Bool = true, emptyText: String = "No Lanes", fontCommands: Bool = true,
                reveal: @escaping () -> Void = {}) {
        self.fontCommands = fontCommands
        self.store = store
        self.menuTitle = menuTitle
        self.labels = labels
        self.numberShortcuts = numberShortcuts
        self.emptyText = emptyText
        self.reveal = reveal
    }

    private var noun: String { labels.laneNoun.capitalized }

    public var body: some Commands {
        CommandMenu(menuTitle) {
            ForEach(Array(store.lanes.prefix(9).enumerated()), id: \.element.id) { index, lane in
                laneButton(lane, index: index)
            }
            if store.lanes.isEmpty {
                Text(emptyText)
            }
            Divider()
            Button("Next \(noun)") {
                reveal()
                store.cycle(by: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(store.lanes.isEmpty)
            Button("Previous \(noun)") {
                reveal()
                store.cycle(by: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(store.lanes.isEmpty)
            Divider()
            Button("Jump to Unread") {
                reveal()
                store.jumpToUnread()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(store.unreadLanes.isEmpty)
            Divider()
            Button("Reattach") {
                reveal()
                if let id = store.selectedID { store.reattach(id) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.selectedID == nil)
            Button("Detach") {
                if let id = store.selectedID { store.detach(id) }
            }
            .disabled(!store.selectedIsAttached)
            Button("Stop Lane") {
                if let id = store.selectedID { store.stop(id) }
            }
            .disabled(store.selectedID.map { !store.canStop($0) } ?? true)
            Button("Clear Screen") { store.clearSelected() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!store.selectedIsAttached)
            if fontCommands {
                Divider()
                Button("Bigger Text") { store.adjustFont(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(store.fontSize >= AgentLaneStore.fontSizeRange.upperBound)
                Button("Smaller Text") { store.adjustFont(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(store.fontSize <= AgentLaneStore.fontSizeRange.lowerBound)
                Button("Actual Size") { store.resetFont() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(store.fontOffset == 0)
            }
            Divider()
            Picker("Sort", selection: Binding(get: { store.layout.sort }, set: { store.setSort($0) })) {
                ForEach(LaneLayout.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button("Collapse All Sections") { store.setAllCollapsed(true) }
                .disabled(store.sectionNames.isEmpty && store.layout.pinned.isEmpty)
            Button("Expand All Sections") { store.setAllCollapsed(false) }
                .disabled(store.layout.collapsed.isEmpty)
            if let id = store.selectedID {
                Button(store.layout.pinned.contains(id) ? "Unpin \(noun)" : "Pin \(noun)") {
                    store.setPinned(id, !store.layout.pinned.contains(id))
                }
            }
            Divider()
            Button("Show \(noun) in Finder") {
                if let path = store.selected?.currentDirectory {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            .disabled(store.selected == nil)
        }
    }

    @ViewBuilder
    private func laneButton(_ lane: AgentLane, index: Int) -> some View {
        let button = Button(store.sessions[lane.id]?.title ?? lane.title) {
            reveal()
            store.open(lane.id)
        }
        if numberShortcuts {
            button.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        } else {
            button
        }
    }
}
