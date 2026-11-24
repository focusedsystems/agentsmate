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

/// A lane's contextual menu: the same commands wherever a lane is listed,
/// the sidebar and All Agents alike. A found (detached) session gets its own,
/// shorter menu.
struct LaneContextMenu: View {
    @ObservedObject var store: AgentLaneStore
    @ObservedObject var session: AgentLaneSession
    let presentation: LaneMenuPresentation
    var rowActions: [LaneAction] = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let host = store.laneLoadStages[session.id]?.unreachableHost {
            Button("Retry \(host)") { store.retryHost(host) }
            Divider()
        }
        if store.isDetached(session.id) {
            detachedMenu
        } else {
            laneMenu
        }
    }

    /// A session found running with no row: reattach it here, adopt it
    /// into a section, or end it.
    @ViewBuilder
    private var detachedMenu: some View {
        let lane = session.lane
        Button("Reattach") { store.reattach(lane.id) }
            .help("Attach this session here; the row stays where it is listed")
        DetachedAdoptMenu(store: store, id: lane.id)
        Divider()
        Button("Stop Session") { store.stop(lane.id) }
            .disabled(!store.canStop(lane.id))
            .help("End the session; its row goes with it")
        Divider()
        if lane.directory != nil {
            Button("Copy Path") { Self.copy(session.currentDirectory) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.currentDirectory)])
            }
        }
        Button("Copy Session Name") { Self.copy(lane.sessionName ?? lane.title) }
    }

    @ViewBuilder
    private var laneMenu: some View {
        let lane = session.lane
        Button("Open \(session.title)") { store.open(lane.id) }
        Button("Reattach") { store.reattach(lane.id) }
            .disabled(!session.isStarted)
        if !store.configuration.reopenChoices.isEmpty {
            Menu("Reopen As") {
                ForEach(store.configuration.reopenChoices, id: \.self) { choice in
                    Button(choice.title) { store.reopen(lane.id, choice: choice) }
                        .disabled(choice.kind != .sameAgent && choice.backendID == lane.backendID && session.isAttached)
                }
            }
        }
        Button("Detach") { store.detach(lane.id) }
            .disabled(!session.isAttached)
        Button("Message…") { store.showMessageAgent(to: lane.id, openWindow: openWindow) }
        if session.needsAttention {
            Button("Mark Read") { store.markRead(lane.id) }
        }
        Button("Change Icon…") { presentation.choosingIcon = lane.id }
        Button("Rename…") { presentation.rename(session) }
        if session.customTitle != nil {
            Button("Use Automatic Name") { store.rename(lane.id, to: nil) }
        }
        Menu("Duplicate") {
            Button("Same Agent") { store.duplicate(lane.id) }
            Divider()
            ForEach(store.availableBackends, id: \.id) { backend in
                Button(backend.displayName) { store.duplicate(lane.id, backendID: backend.id) }
            }
        }
        if lane.isClosable {
            Menu("Switch Agent") {
                ForEach(store.availableBackends, id: \.id) { backend in
                    Button(backend.displayName) {
                        if session.status == .running {
                            presentation.pendingSwitch = .init(id: lane.id, backendID: backend.id, title: session.title)
                        } else {
                            store.switchBackend(lane.id, to: backend.id)
                        }
                    }
                    .disabled(backend.id == lane.backendID)
                }
            }
        }
        if !store.runOnHosts(for: lane.id).isEmpty {
            LaneRunOnMenu(store: store, id: lane.id)
        }
        Divider()
        Button(store.layout.pinned.contains(lane.id) ? "Unpin" : "Pin") {
            store.setPinned(lane.id, !store.layout.pinned.contains(lane.id))
        }
        Menu("Move to Section") {
            Button("None") { store.move(lane.id, to: nil) }
                .disabled(store.layout.section(of: lane) == nil)
            if !store.sectionNames.isEmpty { Divider() }
            ForEach(store.sectionNames, id: \.self) { name in
                Button(name) { store.move(lane.id, to: name) }
                    .disabled(store.layout.section(of: lane) == name)
            }
            Divider()
            Button("New Section…") { presentation.newSection(moving: lane.id) }
        }
        Divider()
        if store.canStop(lane.id) {
            Button("Stop Lane") { store.stop(lane.id) }
                .help("End the session; its conversation resumes when the lane is opened again")
        }
        if lane.isClosable {
            Button("Close") { store.close(lane.id) }
        }
        Divider()
        if !session.displayedPullRequests.isEmpty {
            PullRequestsMenu(pullRequests: session.displayedPullRequests, store: store)
        }
        ForEach(session.rowMetadata.ports, id: \.self) { port in
            Button("Open localhost:\(port)") {
                if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
            }
        }
        if let branch = session.rowMetadata.branch {
            Button("Copy Branch Name") { Self.copy(branch) }
        }
        Button("Copy Path") { Self.copy(session.currentDirectory) }
        if store.summariesAvailable {
            Button("Copy Summary") { store.copySummary(of: lane.id) }
                .disabled(session.summary?.isEmpty ?? true)
        }
        Button("Copy Last Prompt") { store.copyLastPrompt(of: lane.id) }
            .disabled(session.recentPrompts.isEmpty)
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.currentDirectory)])
        }
        if !rowActions.isEmpty {
            Divider()
            ForEach(rowActions) { action in
                Button(action.title) { action.perform(lane) }
                    .disabled(!action.isEnabled(lane))
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
