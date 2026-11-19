import SwiftUI
import AppKit

/// The words Agents mode uses for its lanes, so each app can call them what
/// its people do: areas, sessions, repositories.
public struct AgentsModeLabels: Sendable {
    /// The list's heading, such as "Areas".
    public var listTitle: String
    /// One lane, lower case, such as "area".
    public var laneNoun: String

    public init(listTitle: String = "Lanes", laneNoun: String = "lane") {
        self.listTitle = listTitle
        self.laneNoun = laneNoun
    }
}

/// A command added to each row's contextual menu.
public struct LaneAction: Identifiable {
    public let id = UUID()
    public var title: String
    public var isEnabled: (AgentLane) -> Bool
    public var perform: (AgentLane) -> Void

    public init(_ title: String, isEnabled: @escaping (AgentLane) -> Bool = { _ in true },
                perform: @escaping (AgentLane) -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// The lanes as a native sidebar list: put it in a `NavigationSplitView`'s
/// sidebar column, so it collapses, resizes and draws like every other Mac
/// sidebar. Status filters sit above the list and search is the sidebar's own
/// search field. Every row attaches its lane's persistent session, so the
/// conversation open here is the one other terminals and devices see.
public struct AgentLaneSidebar<Accessory: View>: View {
    @ObservedObject var store: AgentLaneStore
    let labels: AgentsModeLabels
    let rowActions: [LaneAction]
    let accessory: Accessory
    /// Set by ``AgentLaneDock``: outside a split view's sidebar the bars
    /// above and below the list need their own background, and the panel
    /// needs a way to fill the window and come back.
    var inDock = false

    @AppStorage private var filterAttached: Bool
    @AppStorage private var filterRunning: Bool
    @AppStorage private var filterNeedsYou: Bool
    @State private var searchText = ""
    @State private var showingNewSection = false
    @State private var renaming: String?
    @State private var sectionName = ""
    @State private var renamingLane: AgentLane.ID?
    @State private var laneName = ""
    @State private var pendingSwitch: (id: AgentLane.ID, backendID: String, title: String)?
    @State private var savingWorkspace = false
    @State private var workspaceName = ""
    @State private var messaging: AgentLane.ID?
    @State private var choosingIcon: AgentLane.ID?
    @State private var message = ""

    public init(store: AgentLaneStore, labels: AgentsModeLabels = .init(), rowActions: [LaneAction] = [],
                @ViewBuilder accessory: () -> Accessory) {
        self.store = store
        self.labels = labels
        self.rowActions = rowActions
        self.accessory = accessory()
        let keys = store.keys
        _filterAttached = AppStorage(wrappedValue: false, keys.filterOpen)
        _filterRunning = AppStorage(wrappedValue: false, keys.filterRunning)
        _filterNeedsYou = AppStorage(wrappedValue: false, keys.filterWaiting)
    }

    init(store: AgentLaneStore, labels: AgentsModeLabels, inDock: Bool, @ViewBuilder accessory: () -> Accessory) {
        self.init(store: store, labels: labels, accessory: accessory)
        self.inDock = inDock
    }

    public var body: some View {
        List(selection: selectionBinding) {
            ForEach(visibleGroups) { group in
                // The section carrying the header buttons does not fold:
                // its disclosure chevron would flicker in beside them on
                // hover. Sort and Sections › Collapse All still folds it.
                if group.id == store.groups.first?.id {
                    Section {
                        rows(group)
                    } header: {
                        sectionHeader(group)
                    }
                } else {
                    Section(isExpanded: expandedBinding(group)) {
                        rows(group)
                    } header: {
                        sectionHeader(group)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let usage = store.usage {
                VStack(spacing: 0) {
                    Divider()
                    AgentUsageMeter(model: usage).padding(.horizontal, 12).padding(.vertical, 8)
                }
                .background(inDock ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
            }
        }
        .sheet(item: Binding(get: { choosingIcon.map(IconRequest.init) }, set: { choosingIcon = $0?.id })) { request in
            if let session = store.sessions[request.id] {
                LaneIconPicker(icon: session.icon, tintHex: session.tintHex, laneTitle: session.title,
                               canReset: store.layout.icons[request.id] != nil || store.layout.tints[request.id] != nil,
                               onReset: { store.setIcon(nil, tint: nil, for: request.id) }) { icon, tint in
                    store.setIcon(icon, tint: tint, for: request.id)
                }
            }
        }
        .alert("New Section", isPresented: $showingNewSection) {
            TextField("Name", text: $sectionName)
            Button("Add") { store.addSection(sectionName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renamingLane != nil }, set: { if !$0 { renamingLane = nil } })) {
            TextField("Name", text: $laneName)
            Button("Rename") { if let id = renamingLane { store.rename(id, to: laneName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to go back to the automatic name.")
        }
        .alert("Switch the agent?", isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } })) {
            Button("Switch") { if let p = pendingSwitch { store.switchBackend(p.id, to: p.backendID) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(pendingSwitch?.title ?? "This lane") is working. Switching restarts its terminal.")
        }
        .alert("Save Lanes as Workspace", isPresented: $savingWorkspace) {
            TextField("Name", text: $workspaceName)
            Button("Save") { store.saveWorkspace(named: workspaceName.trimmingCharacters(in: .whitespaces)) }
                .disabled(workspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the \(labels.laneNoun)s you opened, with their sections. A workspace with the same name is replaced.")
        }
        .alert("Message", isPresented: Binding(get: { messaging != nil }, set: { if !$0 { messaging = nil } })) {
            TextField("Message", text: $message)
            Button("Send") { if let id = messaging { store.send(message, to: id, submit: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Typed into the agent and sent. If no agent is running there, it goes on the clipboard instead.")
        }
        .alert("Rename Section", isPresented: renamingBinding) {
            TextField("Name", text: $sectionName)
            Button("Rename") { if let old = renaming { store.renameSection(old, to: sectionName) } }
            Button("Cancel", role: .cancel) {}
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search \(labels.laneNoun)s")
        .safeAreaInset(edge: .top, spacing: 0) {
            filterBar
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(inDock ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
        }
        .contextMenu(forSelectionType: AgentLane.ID.self) { ids in
            if let id = ids.first, let session = store.sessions[id] {
                rowMenu(session)
            }
        } primaryAction: { ids in
            if let id = ids.first { store.open(id) }
        }
        .onDeleteCommand {
            if let id = store.selectedID, store.selected?.lane.isClosable == true { store.close(id) }
        }
        .overlay {
            if visibleLanes.isEmpty, !store.lanes.isEmpty {
                VStack(spacing: 6) {
                    Text("No Matching \(labels.listTitle)").font(.callout).foregroundStyle(.secondary)
                    Button("Show All", action: clearFilters).controlSize(.small)
                }
            }
        }
    }

    private var sessions: [AgentLaneSession] { store.lanes.compactMap { store.sessions[$0.id] } }

    @ViewBuilder
    private func rows(_ group: LaneGroup) -> some View {
        ForEach(group.lanes) { lane in
            if let session = store.session(for: lane) {
                LaneRow(session: session,
                        index: displayIndex[lane.id] ?? 99,
                        isSplit: lane.id == store.splitID)
                    .tag(lane.id)
            }
        }
        .onMove { from, to in move(in: group, from: from, to: to) }
    }

    /// The groups with only the lanes the search and filters let through.
    /// While searching every group is shown open, so a match is never hidden.
    private var visibleGroups: [LaneGroup] {
        let visible = Set(visibleLanes.map(\.id))
        let filtering = isFiltering
        return store.groups.compactMap { group in
            var group = group
            group.lanes = group.lanes.filter { visible.contains($0.id) }
            if filtering, group.lanes.isEmpty { return nil }
            return group
        }
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || filterAttached || filterRunning || filterNeedsYou
    }

    private var displayIndex: [AgentLane.ID: Int] {
        Dictionary(uniqueKeysWithValues: store.displayOrder.enumerated().map { ($1.id, $0) })
    }

    private func expandedBinding(_ group: LaneGroup) -> Binding<Bool> {
        let key = group.isPinned ? LaneLayout.pinnedSection : group.section
        return Binding(
            get: { isFiltering || key.map { !store.layout.collapsed.contains($0) } ?? true },
            set: { open in
                guard let key, !isFiltering else { return }
                if open == store.layout.collapsed.contains(key) { store.toggleCollapsed(key) }
            })
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    /// Dragging within a group sets the manual order (and switches the sort
    /// to manual, since a recency sort would undo the move at once).
    private func move(in group: LaneGroup, from source: IndexSet, to destination: Int) {
        var ids = group.lanes.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        let moved = source.map { group.lanes[$0].id }
        let after = destination < group.lanes.count ? group.lanes[destination].id : nil
        for id in moved { store.moveLane(id, before: after.flatMap { moved.contains($0) ? nil : $0 }) }
        if store.layout.sort != .manual { store.setSort(.manual) }
    }

    @ViewBuilder
    private func sectionHeader(_ group: LaneGroup) -> some View {
        HStack {
            Text(group.isPinned ? LaneLayout.pinnedSection : group.section ?? labels.listTitle)
            Spacer()
            if group.id == store.groups.first?.id { accessory }
        }
        .contextMenu {
            if let name = group.section, !group.isPinned {
                Button("Rename Section…") { sectionName = name; renaming = name }
                Button("Move Section Up") { store.moveSection(name, by: -1) }
                Button("Move Section Down") { store.moveSection(name, by: 1) }
                Button("Remove Section") { store.removeSection(name) }
                Divider()
            }
            Button("New Section…") { sectionName = ""; showingNewSection = true }
            Divider()
            Button("Collapse All") { store.setAllCollapsed(true) }
            Button("Expand All") { store.setAllCollapsed(false) }
        }
    }

    private var selectionBinding: Binding<AgentLane.ID?> {
        Binding(get: { store.selectedID },
                set: { id in
                    // A click hands the keyboard to the lane's terminal so
                    // typing goes straight to the agent. Moving through the
                    // list with the arrow keys attaches each lane but leaves
                    // the keyboard in the list; Return then hands it over.
                    let fromKeyboard = NSApp.currentEvent?.type == .keyDown
                    if let id { store.open(id, focus: !fromKeyboard) }
                })
    }

    @ViewBuilder
    private func rowMenu(_ session: AgentLaneSession) -> some View {
        let lane = session.lane
        Button("Open \(session.title)") { store.open(lane.id) }
        Button("Reattach") { store.reattach(lane.id) }
            .disabled(!session.isStarted)
        if !store.configuration.reopenChoices.isEmpty {
            Menu("Reopen As") {
                ForEach(store.configuration.reopenChoices, id: \.self) { choice in
                    Button(choice.title) { store.reopen(lane.id, as: choice.backendID) }
                        .disabled(choice.backendID == lane.backendID && session.isAttached)
                }
            }
        }
        Button("Detach") { store.detach(lane.id) }
            .disabled(!session.isAttached)
        Button("Message…") { message = ""; messaging = lane.id }
            .disabled(!session.isAttached)
        Button("Change Icon…") { choosingIcon = lane.id }
        Button("Rename…") { laneName = session.customTitle ?? session.title; renamingLane = lane.id }
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
                            pendingSwitch = (lane.id, backend.id, session.title)
                        } else {
                            store.switchBackend(lane.id, to: backend.id)
                        }
                    }
                    .disabled(backend.id == lane.backendID)
                }
            }
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
            Button("New Section…") { sectionName = ""; showingNewSection = true }
        }
        Divider()
        if session.backend.canStop {
            Button("Stop Lane") { store.stop(lane.id) }
                .help("End the session; its conversation resumes when the lane is opened again")
        }
        if lane.isClosable {
            Button("Close") { store.close(lane.id) }
        }
        Divider()
        if let pr = session.rowMetadata.pullRequest, let url = pr.url {
            Button("Open Pull Request #\(pr.number)") { NSWorkspace.shared.open(url) }
        }
        ForEach(session.rowMetadata.ports, id: \.self) { port in
            Button("Open localhost:\(port)") {
                if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
            }
        }
        if session.rowMetadata.branch != nil {
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.rowMetadata.branch ?? "", forType: .string)
            }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.currentDirectory, forType: .string)
        }
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

    private var visibleLanes: [AgentLane] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return store.lanes.filter { lane in
            guard let session = store.session(for: lane) else { return false }
            if !query.isEmpty, !session.title.lowercased().contains(query),
               !lane.path.lowercased().contains(query) { return false }
            if filterAttached, !session.isAttached { return false }
            if filterRunning, session.status != .running { return false }
            if filterNeedsYou, !Self.wantsYou(session.status) { return false }
            return true
        }
    }

    static func wantsYou(_ status: LaneDisplayStatus) -> Bool {
        status == .waitingForInput || status == .permissionRequested
    }

    private func clearFilters() {
        filterAttached = false
        filterRunning = false
        filterNeedsYou = false
        searchText = ""
    }

    /// Status toggles with their counts.
    private var filterBar: some View {
        let all = sessions
        return HStack(spacing: 2) {
            LaneFilterToggle(symbol: "circle.fill", symbolScale: 0.7, title: "Attached",
                             help: "Show only \(labels.laneNoun)s attached here",
                             count: all.filter(\.isAttached).count, isOn: $filterAttached)
            LaneFilterToggle(symbol: "bolt.fill", symbolScale: 1, title: "Running",
                             help: "Show only \(labels.laneNoun)s whose agent is working",
                             count: all.filter { $0.status == .running }.count, isOn: $filterRunning)
            LaneFilterToggle(symbol: "hand.raised.fill", symbolScale: 1, title: "Needs You",
                             help: "Show only \(labels.laneNoun)s waiting for input or permission",
                             count: all.filter { Self.wantsYou($0.status) }.count, isOn: $filterNeedsYou)
            Spacer(minLength: 0)
            Menu {
                Picker("Sort", selection: Binding(get: { store.layout.sort }, set: { store.setSort($0) })) {
                    ForEach(LaneLayout.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("New Section…") { sectionName = ""; showingNewSection = true }
                Button("Collapse All") { store.setAllCollapsed(true) }
                Button("Expand All") { store.setAllCollapsed(false) }
                if store.configuration.workspaceFile != nil {
                    Divider()
                    Menu("Workspaces") {
                        AgentWorkspaceMenu(store: store) { workspaceName = ""; savingWorkspace = true }
                    }
                }
            } label: {
                Label("Sort and Sections", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort the list, or add and fold sections")
            if inDock {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { store.dockMaximized.toggle() }
                } label: {
                    Label(store.dockMaximized ? "Restore Panel" : "Fill Window",
                          systemImage: store.dockMaximized ? "arrow.down.right.and.arrow.up.left"
                                                           : "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(store.dockMaximized ? "Back to the split under the content (⇧⌘↩)" : "Fill the window (⇧⌘↩)")
            }
        }
    }
}

public extension AgentLaneSidebar where Accessory == EmptyView {
    init(store: AgentLaneStore, labels: AgentsModeLabels = .init(), rowActions: [LaneAction] = []) {
        self.init(store: store, labels: labels, rowActions: rowActions, accessory: { EmptyView() })
    }
}

/// The selected lane's live terminal, and a second beside it when split: put
/// it in a `NavigationSplitView`'s detail column. `empty` shows when the app
/// has no lanes.
public struct AgentLaneDetail<Empty: View>: View {
    @ObservedObject var store: AgentLaneStore
    let empty: Empty

    public init(store: AgentLaneStore, @ViewBuilder empty: () -> Empty) {
        self.store = store
        self.empty = empty()
    }

    public var body: some View {
        Group {
            if store.lanes.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    if let session = store.selected {
                        LaneTerminalPane(session: session, store: store)
                    } else {
                        Color.clear
                    }
                    if let split = store.split, split.id != store.selectedID {
                        Divider()
                        LaneTerminalPane(session: split, store: store)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .agentLanePalette(store)
        .onAppear {
            store.isShowing = true
            store.openSelected(focus: true)
        }
        .onDisappear { store.isShowing = false }
    }
}

/// Agents mode as a whole window's content: the native sidebar of lanes and
/// the terminal beside it. An app that already has a `NavigationSplitView`
/// puts ``AgentLaneSidebar`` and ``AgentLaneDetail`` in its own columns
/// instead, so switching modes keeps the same window chrome.
public struct AgentsModeView<Accessory: View, Empty: View>: View {
    @ObservedObject var store: AgentLaneStore
    let labels: AgentsModeLabels
    let rowActions: [LaneAction]
    let accessory: Accessory
    let empty: Empty

    public init(store: AgentLaneStore, labels: AgentsModeLabels = .init(), rowActions: [LaneAction] = [],
                @ViewBuilder accessory: () -> Accessory, @ViewBuilder empty: () -> Empty) {
        self.store = store
        self.labels = labels
        self.rowActions = rowActions
        self.accessory = accessory()
        self.empty = empty()
    }

    public var body: some View {
        NavigationSplitView {
            AgentLaneSidebar(store: store, labels: labels, rowActions: rowActions) { accessory }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 420)
        } detail: {
            AgentLaneDetail(store: store) { empty }
        }
    }
}

public extension AgentsModeView where Accessory == EmptyView {
    init(store: AgentLaneStore, labels: AgentsModeLabels = .init(), rowActions: [LaneAction] = [],
         @ViewBuilder empty: () -> Empty) {
        self.init(store: store, labels: labels, rowActions: rowActions, accessory: { EmptyView() }, empty: empty)
    }
}

/// One lane's terminal, with a bar to reattach once it has ended.
struct LaneTerminalPane: View {
    @ObservedObject var session: AgentLaneSession
    let store: AgentLaneStore

    var body: some View {
        VStack(spacing: 0) {
            if session.isStarted {
                TerminalHost(session: session)
                    .id("\(session.id)#\(session.generation)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if session.hasExited {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text(session.backend.keepsRunningWhenDetached
                         ? "Detached from \(session.title). The agent keeps running in its lane."
                         : "\(session.title) has ended.")
                        .font(.callout)
                    Spacer()
                    Button(session.backend.keepsRunningWhenDetached ? "Reattach" : "Start Again") {
                        store.reattach(session.id)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }
}

private struct IconRequest: Identifiable { let id: AgentLane.ID }

struct LaneRow: View {
    @ObservedObject var session: AgentLaneSession
    let index: Int
    let isSplit: Bool

    var body: some View {
        HStack(spacing: 8) {
            LaneIconView(icon: session.icon, tintHex: session.tintHex, size: 16)
                .frame(width: 20)
                .overlay(alignment: .bottomTrailing) { statusDot.offset(x: 3, y: 3) }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 2)
            if let pr = session.rowMetadata.pullRequest {
                Text("#\(pr.number)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Self.color(for: pr.state).opacity(0.18)))
                    .foregroundStyle(Self.color(for: pr.state))
                    .help("Pull request #\(pr.number), \(pr.state.rawValue)")
                    .accessibilityLabel("Pull request \(pr.number), \(pr.state.rawValue)")
            }
            if let progress = session.note?.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .help("\(Int(progress * 100))% done")
            }
            if !session.rowMetadata.ports.isEmpty {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Listening on " + session.rowMetadata.ports.map(String.init).joined(separator: ", "))
                    .accessibilityLabel("Listening on ports " + session.rowMetadata.ports.map(String.init).joined(separator: ", "))
            }
            if session.needsAttention {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            if index < 9 {
                Text("⌘\(index + 1)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.title)
        .accessibilityValue(session.isOrphan ? "Running, nothing attached"
                            : session.needsAttention ? "\(session.status.title), new" : session.status.title)
    }

    private var isActive: Bool {
        switch session.status {
        case .running, .waitingForInput, .permissionRequested: true
        default: false
        }
    }

    private var subtitle: String {
        let base = statusSubtitle
        guard let branch = session.rowMetadata.branch else { return base }
        return base + " · " + branch
    }

    private var statusSubtitle: String {
        if let text = session.note?.text { return text }
        if let summary = session.summary, session.status != .running { return summary }
        if session.isOrphan, !session.isAttached { return "Running, nothing attached" }
        if session.lane.isClosable, session.status == .attached || session.status == .detached {
            return session.shortDirectory
        }
        return isSplit ? "\(session.status.title) · split" : session.status.title
    }

    static func color(for state: LaneRowMetadata.PullRequest.State) -> Color {
        switch state {
        case .open: .green
        case .draft: .secondary
        case .merged: .purple
        case .closed: .red
        }
    }

    private var helpText: String {
        var lines = ["\(session.title) — \(session.status.title)", session.shortDirectory]
        if !session.recentPrompts.isEmpty {
            lines.append("Recent requests:")
            lines.append(contentsOf: session.recentPrompts.map { "• " + String($0.prefix(140)) })
        }
        if let note = session.note {
            if let progress = note.progress { lines.append("\(Int(progress * 100))% done") }
            lines.append(contentsOf: note.log.suffix(5))
        }
        if let message = session.record?.message, !message.isEmpty { lines.append(message) }
        return lines.joined(separator: "\n")
    }

    /// Green while the agent works, orange when it asks permission, blue
    /// while it waits for you, grey when done or attached and quiet, an
    /// outline when not attached here.
    @ViewBuilder
    private var statusDot: some View {
        if session.isOrphan {
            Circle().strokeBorder(Color.orange, lineWidth: 1.5).frame(width: 8, height: 8)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        } else {
            statusDotForStatus
        }
    }

    @ViewBuilder
    private var statusDotForStatus: some View {
        switch session.status {
        case .notOpened, .detached:
            Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 7, height: 7)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        case .running:
            Circle().fill(Color.green).frame(width: 7, height: 7)
        case .permissionRequested:
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        case .waitingForInput:
            Circle().fill(Color.blue).frame(width: 7, height: 7)
        case .done, .idle, .attached:
            Circle().fill(Color.secondary).frame(width: 7, height: 7)
        }
    }
}

/// A status filter: an icon and its count, tinted while it is on.
struct LaneFilterToggle: View {
    let symbol: String
    let symbolScale: CGFloat
    let title: String
    let help: String
    let count: Int
    @Binding var isOn: Bool
    @State private var hovered = false

    private var isDisabled: Bool { count == 0 && !isOn }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 10 * symbolScale, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.15)
                          : hovered && !isDisabled ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .onHover { hovered = $0 }
        .help(isOn ? "Show all" : help)
        .accessibilityLabel(title)
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Hosts a session's terminal and hands it keyboard focus once it is
/// actually in a window — focus asked for before then is silently dropped.
final class TerminalContainer: NSView {
    var session: AgentLaneSession?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfWanted()
    }

    func focusIfWanted() {
        guard let session, session.wantsFocus, let window else { return }
        // Deferred: this runs inside a SwiftUI update, which must not publish.
        DispatchQueue.main.async {
            session.wantsFocus = false
            window.makeFirstResponder(session.view)
        }
    }
}

/// The terminal drawn by a session, hosted in SwiftUI. The session owns the
/// view, so the same NSView is re-hosted when the pane reappears.
struct TerminalHost: NSViewRepresentable {
    @ObservedObject var session: AgentLaneSession

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        if session.view.superview !== container { attach(to: container) }
        container.focusIfWanted()
    }

    private func attach(to container: TerminalContainer) {
        container.session = session
        container.subviews.forEach { $0.removeFromSuperview() }
        session.view.removeFromSuperview()
        session.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(session.view)
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            session.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            session.view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            session.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.focusIfWanted()
    }
}

extension Color {
    /// `#RRGGBB` or `RRGGBB`.
    init?(laneHex: String) {
        var hex = laneHex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

