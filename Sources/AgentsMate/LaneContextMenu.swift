import SwiftUI
import AppKit

/// The dialogs a lane's contextual menu can ask for: rename, change icon,
/// confirm an agent switch, new section. One per view that shows lane menus
/// (the sidebar, All Agents), presented by ``LaneMenuSheets`` on that view.
@MainActor
final class LaneMenuPresentation: ObservableObject {
    @Published var renamingLane: AgentLane.ID?
    @Published var laneName = ""
    @Published var pendingSwitch: PendingSwitch?
    @Published var choosingIcon: AgentLane.ID?
    @Published var showingNewSection = false
    @Published var newSectionName = ""
    /// The row a New Section… from its menu moves into the new section.
    @Published var newSectionLane: AgentLane.ID?
    /// The lane Stop Agent… is asking about.
    @Published var pendingStop: PendingStop?

    struct PendingStop: Equatable {
        var id: AgentLane.ID
        var title: String
    }

    struct PendingSwitch: Equatable {
        var id: AgentLane.ID
        var backendID: String
        var title: String
    }

    func rename(_ session: AgentLaneSession) {
        laneName = session.customTitle ?? session.title
        renamingLane = session.id
    }

    func newSection(moving laneID: AgentLane.ID? = nil) {
        newSectionName = ""
        newSectionLane = laneID
        showingNewSection = true
    }
}

/// Presents what a ``LaneContextMenu`` asked for: the icon picker sheet and
/// the rename, switch and new-section alerts.
struct LaneMenuSheets: ViewModifier {
    @ObservedObject var store: AgentLaneStore
    @ObservedObject var presentation: LaneMenuPresentation

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { presentation.choosingIcon.map(IconRequest.init) },
                                 set: { presentation.choosingIcon = $0?.id })) { request in
                if let session = store.sessions[request.id] {
                    LaneIconPicker(icon: session.icon, tintHex: session.tintHex, laneTitle: session.title,
                                   canReset: store.layout.icons[request.id] != nil || store.layout.tints[request.id] != nil,
                                   onReset: { store.setIcon(nil, tint: nil, for: request.id) }) { icon, tint in
                        store.setIcon(icon, tint: tint, for: request.id)
                    }
                }
            }
            .alert("New Section", isPresented: $presentation.showingNewSection) {
                TextField("Name", text: $presentation.newSectionName)
                Button("Add") {
                    let name = presentation.newSectionName.trimmingCharacters(in: .whitespaces)
                    store.addSection(name)
                    // An empty section is not listed, so one made from a
                    // row's menu takes that row with it.
                    if let id = presentation.newSectionLane, store.sectionNames.contains(name) {
                        store.move(id, to: name)
                    }
                    presentation.newSectionLane = nil
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: Binding(get: { presentation.renamingLane != nil },
                                                  set: { if !$0 { presentation.renamingLane = nil } })) {
                TextField("Name", text: $presentation.laneName)
                Button("Rename") {
                    if let id = presentation.renamingLane { store.rename(id, to: presentation.laneName) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave it empty to go back to the automatic name.")
            }
            .alert("Stop \(presentation.pendingStop?.title ?? "this agent")?",
                   isPresented: Binding(get: { presentation.pendingStop != nil },
                                        set: { if !$0 { presentation.pendingStop = nil } })) {
                Button("Stop Agent", role: .destructive) {
                    if let p = presentation.pendingStop { store.stop(p.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This ends the agent's process. Its conversation is kept, and opening the lane again resumes it. Close leaves the agent running instead.")
            }
            .alert("Switch the agent?", isPresented: Binding(get: { presentation.pendingSwitch != nil },
                                                             set: { if !$0 { presentation.pendingSwitch = nil } })) {
                Button("Switch") {
                    if let p = presentation.pendingSwitch { store.switchBackend(p.id, to: p.backendID) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(presentation.pendingSwitch?.title ?? "This lane") is working. Switching restarts its terminal.")
            }
    }
}

private struct IconRequest: Identifiable { let id: AgentLane.ID }

/// A lane's menu: the same commands, in the same order, with the same names
/// and shortcuts, wherever a lane is listed (the sidebar, All Agents, the menu
/// bar's Agent menu) and in every app. ``LaneMenuPlan`` is the list; an app
/// adds its own items after the shared ones with `rowActions`.
struct LaneContextMenu: View {
    @ObservedObject var store: AgentLaneStore
    @ObservedObject var session: AgentLaneSession
    var rowActions: [LaneAction] = []
    /// Commands left out because the menu already lists them.
    var hiding: Set<LaneMenuCommand> = []
    var reveal: () -> Void = {}
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let host = store.laneLoadStages[session.id]?.unreachableHost {
            Button("Retry \(host)") { store.retryHost(host) }
            Divider()
        }
        let state = store.menuState(for: session, hasAppItems: !rowActions.isEmpty)
        let items = Self.visible(LaneMenuPlan.items(state), hiding: hiding)
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            render(item)
        }
    }

    /// The plan without the hidden commands, and without a divider left
    /// at an end or doubled.
    static func visible(_ items: [LaneMenuItem], hiding: Set<LaneMenuCommand>) -> [LaneMenuItem] {
        var result: [LaneMenuItem] = []
        for item in items {
            if case .command(let command) = item, hiding.contains(command) { continue }
            if item == .divider, result.isEmpty || result.last == .divider { continue }
            result.append(item)
        }
        if result.last == .divider { result.removeLast() }
        return result
    }

    @ViewBuilder
    private func render(_ item: LaneMenuItem) -> some View {
        let lane = session.lane
        switch item {
        case .divider:
            Divider()
        case .command(let command):
            LaneMenuButton(store: store, session: session, command: command, reveal: reveal)
        case .ports:
            ForEach(session.rowMetadata.ports, id: \.self) { port in
                Button("Open localhost:\(port)") {
                    if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                }
            }
        case .appItems:
            ForEach(rowActions) { action in
                Button(action.title) { action.perform(lane) }
                    .disabled(!action.isEnabled(lane))
            }
        case .submenu(.reopenAs):
            Menu("Reopen As") {
                ForEach(Array(store.configuration.reopenChoices.enumerated()), id: \.offset) { _, choice in
                    Button(choice.title) {
                        reveal()
                        store.reopen(lane.id, choice: choice)
                    }
                    .laneShortcut(store.reopenMenuBinding(for: choice))
                    .disabled(choice.kind != .sameAgent && choice.backendID == lane.backendID && session.isAttached)
                }
            }
        case .submenu(.duplicate):
            Menu("Duplicate") {
                Button("Same Agent") { store.duplicate(lane.id) }
                    .disabled(!store.canDuplicate(lane.id))
                Divider()
                ForEach(store.availableBackends, id: \.id) { backend in
                    Button(backend.displayName) { store.duplicate(lane.id, backendID: backend.id) }
                        .disabled(!store.canDuplicate(lane.id, backendID: backend.id))
                }
            }
        case .submenu(.switchAgent):
            Menu("Switch Agent") {
                ForEach(store.availableBackends, id: \.id) { backend in
                    Button(backend.displayName) {
                        reveal()
                        if session.status == .running {
                            store.menus.pendingSwitch = .init(id: lane.id, backendID: backend.id, title: session.title)
                        } else {
                            store.switchBackend(lane.id, to: backend.id)
                        }
                    }
                    .disabled(backend.id == lane.backendID)
                }
            }
        case .submenu(.runOn):
            LaneRunOnMenu(store: store, id: lane.id, reveal: reveal)
        case .submenu(.adopt):
            DetachedAdoptMenu(store: store, id: lane.id)
        case .submenu(.moveToSection):
            Menu("Move to Section") {
                Button("None") { store.move(lane.id, to: nil) }
                    .disabled(store.layout.section(of: lane) == nil)
                if !store.sectionNames.isEmpty { Divider() }
                ForEach(store.sectionNames, id: \.self) { name in
                    Button(name) { store.move(lane.id, to: name) }
                        .disabled(store.layout.section(of: lane) == name)
                }
                Divider()
                Button("New Section…") {
                    reveal()
                    store.menus.newSection(moving: lane.id)
                }
            }
        case .submenu(.pullRequests):
            PullRequestsMenu(pullRequests: session.displayedPullRequests, store: store)
        }
    }
}
