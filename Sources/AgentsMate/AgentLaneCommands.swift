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
    /// The id of the app's inbox window scene, if it has one.
    let inboxWindowID: String?
    /// Back and Forward through lanes visited, on ⌘[ and ⌘].
    let historyCommands: Bool
    /// The row selected in the inbox, when the inbox window is in front.
    @FocusedValue(\.agentInboxSelection) private var inboxSelection

    public init(store: AgentLaneStore, menuTitle: String = "Agent", labels: AgentsModeLabels = .init(),
                numberShortcuts: Bool = true, emptyText: String = "No Lanes", fontCommands: Bool = true,
                inboxWindowID: String? = nil, historyCommands: Bool = true, reveal: @escaping () -> Void = {}) {
        self.historyCommands = historyCommands
        self.inboxWindowID = inboxWindowID
        self.fontCommands = fontCommands
        self.store = store
        self.menuTitle = menuTitle
        self.labels = labels
        self.numberShortcuts = numberShortcuts
        self.emptyText = emptyText
        self.reveal = reveal
    }

    private var noun: String { labels.laneNoun.capitalized }

    /// Mark Read acts on the inbox's selected row while the inbox is in
    /// front, and on the selected lane otherwise.
    private var markReadTarget: AgentLane.ID? { inboxSelection ?? store.selectedID }

    /// The group of the selected lane, where New Lane in Section starts one.
    private var selectedGroup: LaneGroup? { store.selectedID.flatMap { store.group(containing: $0) } }

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
            .laneShortcut(store.shortcuts.binding(for: .next))
            .disabled(store.lanes.isEmpty)
            Button("Previous \(noun)") {
                reveal()
                store.cycle(by: -1)
            }
            .laneShortcut(store.shortcuts.binding(for: .previous))
            .disabled(store.lanes.isEmpty)
            Divider()
            if let inboxID = inboxWindowID ?? store.configuration.inboxWindowID {
                AgentInboxMenuItem(store: store, windowID: inboxID)
            }
            Button("Jump to Unread") {
                reveal()
                store.jumpToUnread()
            }
            .laneShortcut(store.shortcuts.binding(for: .jumpToUnread))
            .disabled(store.unreadLanes.isEmpty)
            Button("Mark Read") { if let id = markReadTarget { store.markRead(id) } }
                .disabled(markReadTarget.flatMap { store.sessions[$0]?.needsAttention } != true)
            Button("Mark All Read") { store.markAllRead() }
                .disabled(store.unreadLanes.isEmpty)
            AgentMessageMenuItem(store: store, reveal: reveal)
            Button("Go to \(noun)…") {
                reveal()
                store.paletteVisible = true
            }
            .laneShortcut(store.shortcuts.binding(for: .goToLane))
            .disabled(store.lanes.isEmpty)
            if historyCommands {
                Button("Back") { reveal(); store.goBack() }
                    .laneShortcut(store.shortcuts.binding(for: .back))
                    .disabled(!store.canGoBack)
                Button("Forward") { reveal(); store.goForward() }
                    .laneShortcut(store.shortcuts.binding(for: .forward))
                    .disabled(!store.canGoForward)
            }
            Divider()
            Menu("New \(noun) in Section") {
                ForEach(store.availableBackends, id: \.id) { backend in
                    Button("\(backend.displayName)…") {
                        reveal()
                        if let group = selectedGroup { Task { await store.newLane(in: group, backendID: backend.id) } }
                    }
                }
            }
            .disabled(selectedGroup.map { !store.canAddLane(to: $0) } ?? true)
            Button("Reattach") {
                reveal()
                if let id = store.selectedID { store.reattach(id) }
            }
            .laneShortcut(store.shortcuts.binding(for: .reattach))
            .disabled(store.selectedID == nil)
            LaneReopenMenu(store: store, reveal: reveal)
            Button("Detach") {
                if let id = store.selectedID { store.detach(id) }
            }
            .disabled(!store.selectedIsAttached)
            Button("Stop Lane") {
                if let id = store.selectedID { store.stop(id) }
            }
            .disabled(store.selectedID.map { !store.canStop($0) } ?? true)
            DetachedAdoptMenu(store: store, id: store.selectedID)
            Button("Look for Detached Sessions") { store.sweepForDetachedSessions() }
                .disabled(!store.configuration.findsDetachedSessions)
            Button("Clear Screen") { store.clearSelected() }
                .laneShortcut(store.shortcuts.binding(for: .clear))
                .disabled(!store.selectedIsAttached)
            if fontCommands {
                Divider()
                Button("Bigger Text") { store.adjustFont(by: 1) }
                    .laneShortcut(store.shortcuts.binding(for: .biggerFont))
                    .disabled(store.fontSize >= AgentLaneStore.fontSizeRange.upperBound)
                Button("Smaller Text") { store.adjustFont(by: -1) }
                    .laneShortcut(store.shortcuts.binding(for: .smallerFont))
                    .disabled(store.fontSize <= AgentLaneStore.fontSizeRange.lowerBound)
                Button("Actual Size") { store.resetFont() }
                    .laneShortcut(store.shortcuts.binding(for: .resetFont))
                    .disabled(store.fontOffset == 0)
            }
            Divider()
            Picker("Sort", selection: Binding(get: { store.layout.sort }, set: { store.setSort($0) })) {
                ForEach(LaneLayout.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button("Collapse Other Sections") {
                reveal()
                store.collapseOtherSectionsThanSelected()
            }
            .disabled(store.selectedID.flatMap { store.group(containing: $0) }
                .map { !store.canCollapseOtherSections(than: $0) } ?? true)
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
            if store.summariesAvailable {
                Button("Copy Summary") { if let id = store.selectedID { store.copySummary(of: id) } }
                    .disabled(store.selected?.summary?.isEmpty ?? true)
            }
            Button("Copy Last Prompt") { if let id = store.selectedID { store.copyLastPrompt(of: id) } }
                .disabled(store.selected?.recentPrompts.isEmpty ?? true)
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
