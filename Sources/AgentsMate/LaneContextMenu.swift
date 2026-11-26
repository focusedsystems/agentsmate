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
    /// How an item that cannot run now is shown: a contextual menu leaves it
    /// out, the menu bar's Agent menu dims it so the menu keeps its shape.
    var unavailable: Unavailable = .hidden
    var reveal: () -> Void = {}
    @Environment(\.openWindow) private var openWindow

    enum Unavailable { case hidden, dimmed }

    private var hidesUnavailable: Bool { unavailable == .hidden }

    var body: some View {
        if let host = store.laneLoadStages[session.id]?.unreachableHost {
            Button("Retry \(host)") { store.retryHost(host) }
            Divider()
        }
        let state = store.menuState(for: session, hasAppItems: !rowActions.isEmpty)
        let items = Self.visible(LaneMenuPlan.items(state), hiding: hiding) { item in
            !hidesUnavailable || isAvailable(item)
        }
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            render(item)
        }
    }

    /// Whether an item can do anything now: a command that is enabled, or a
    /// submenu with at least one enabled item.
    private func isAvailable(_ item: LaneMenuItem) -> Bool {
        let lane = session.lane
        switch item {
        case .command(let command): return store.isEnabled(command, for: session)
        case .submenu(.switchAgent):
            return LaneMenuPlan.switchAgentCommands.contains { store.isEnabled($0, for: session) }
                || store.switchAgentBackends(for: lane.id).contains { $0.id != lane.backendID }
        case .submenu(.duplicate):
            return store.canDuplicate(lane.id)
                || store.availableBackends.contains { store.canDuplicate(lane.id, backendID: $0.id) }
        case .appItems: return rowActions.contains { $0.isEnabled(lane) }
        default: return true
        }
    }

    /// The plan without the hidden commands, without the items `include`
    /// leaves out, and without a divider left at an end or doubled.
    static func visible(_ items: [LaneMenuItem], hiding: Set<LaneMenuCommand>,
                        include: (LaneMenuItem) -> Bool = { _ in true }) -> [LaneMenuItem] {
        var result: [LaneMenuItem] = []
        for item in items {
            if case .command(let command) = item, hiding.contains(command) { continue }
            if item != .divider, !include(item) { continue }
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
                if shows(action.isEnabled(lane)) {
                    Button(action.title) { action.perform(lane) }
                        .disabled(!action.isEnabled(lane))
                }
            }
        case .submenu(.duplicate):
            Menu("Duplicate") {
                let backends = store.availableBackends.filter { shows(store.canDuplicate(lane.id, backendID: $0.id)) }
                if shows(store.canDuplicate(lane.id)) {
                    Button("Same Agent") { store.duplicate(lane.id) }
                        .disabled(!store.canDuplicate(lane.id))
                    if !backends.isEmpty { Divider() }
                }
                ForEach(backends, id: \.id) { backend in
                    Button(backend.displayName) { store.duplicate(lane.id, backendID: backend.id) }
                        .disabled(!store.canDuplicate(lane.id, backendID: backend.id))
                }
            }
        case .submenu(.switchAgent):
            switchAgentMenu(lane)
        case .submenu(.runOn):
            LaneRunOnMenu(store: store, id: lane.id, reveal: reveal)
        case .submenu(.adopt):
            DetachedAdoptMenu(store: store, id: lane.id)
        case .submenu(.moveToSection):
            Menu("Move to Section") {
                let current = store.layout.section(of: lane)
                let sections = store.sectionNames.filter { shows(current != $0) }
                if shows(current != nil) {
                    Button("None") { store.move(lane.id, to: nil) }
                        .disabled(current == nil)
                    if !sections.isEmpty { Divider() }
                }
                ForEach(sections, id: \.self) { name in
                    Button(name) { store.move(lane.id, to: name) }
                        .disabled(current == name)
                }
                Divider()
                Button("New Section…") {
                    reveal()
                    store.menus.newSection(moving: lane.id)
                }
            }
        case .submenu(.pullRequests):
            PullRequestsMenu(pullRequests: session.displayedPullRequests, store: store)
        default:
            EmptyView()
        }
    }

    /// Whether to list an item that is `enabled` or not.
    private func shows(_ enabled: Bool) -> Bool { enabled || !hidesUnavailable }

    /// Claude and Codex on ⇧⌘C and ⇧⌘X, then every backend the lane can
    /// run on, each on its Reopen As key where the app gives it one.
    @ViewBuilder
    private func switchAgentMenu(_ lane: AgentLane) -> some View {
        Menu("Switch Agent") {
            let commands = LaneMenuPlan.switchAgentCommands.filter { shows(store.isEnabled($0, for: session)) }
            let backends = store.switchAgentBackends(for: lane.id).filter { shows($0.id != lane.backendID) }
            ForEach(commands, id: \.self) { command in
                LaneMenuButton(store: store, session: session, command: command, reveal: reveal)
            }
            if !commands.isEmpty, !backends.isEmpty { Divider() }
            ForEach(backends, id: \.id) { backend in
                Button(backend.displayName) {
                    reveal()
                    store.switchFromMenu(session, to: backend.id)
                }
                .laneShortcut(store.reopenMenuBinding(forBackend: backend.id))
                .disabled(backend.id == lane.backendID)
            }
        }
    }
}

extension AgentLaneStore {
    /// The backends a lane's Switch Agent submenu lists: every one for a lane
    /// the person added, and the app's Reopen As choices for one the app lists.
    func switchAgentBackends(for id: AgentLane.ID) -> [any LaneBackend] {
        guard let lane = lanes.first(where: { $0.id == id }) else { return [] }
        if lane.isClosable { return availableBackends }
        var seen = Set<String>()
        return configuration.reopenChoices
            .filter { $0.kind != .sameAgent && seen.insert($0.backendID).inserted }
            .compactMap { backends[$0.backendID] }
    }

    /// Run a lane on `backendID` from its Switch Agent submenu. A lane the
    /// person added restarts on it, after asking while its agent is working;
    /// a lane the app lists reopens on it and leaves its session running.
    func switchFromMenu(_ session: AgentLaneSession, to backendID: String) {
        let lane = session.lane
        guard lane.isClosable else { return reopen(lane.id, as: backendID) }
        if session.status == .running {
            menus.pendingSwitch = .init(id: lane.id, backendID: backendID, title: session.title)
        } else {
            switchBackend(lane.id, to: backendID)
        }
    }

    /// The Reopen As key of the app's choice for `backendID`, if it has one.
    func reopenMenuBinding(forBackend backendID: String) -> LaneKeyBinding? {
        configuration.reopenChoices.first { $0.kind != .sameAgent && $0.backendID == backendID }
            .flatMap(reopenMenuBinding(for:))
    }
}
