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

    /// The narrowest the list may be, whatever the controls above it need:
    /// apps that put the sidebar in their own split view can start from it.
    public static var minimumWidth: CGFloat { AgentLaneStore.sidebarBaseMinimumWidth }

    @State private var chipsWidth: CGFloat = 0
    @State private var controlsWidth: CGFloat = 0

    @AppStorage private var filterAttached: Bool
    @AppStorage private var filterRunning: Bool
    @AppStorage private var filterNeedsYou: Bool
    @AppStorage private var filterIdle: Bool
    @AppStorage private var filterUnread: Bool
    @AppStorage private var showsHeadings: Bool
    @AppStorage private var showsIcons: Bool
    @AppStorage private var showsPullRequests: Bool
    @AppStorage private var parallelPlacement: String
    @State private var searchText = ""
    @State private var renaming: String?
    @State private var sectionName = ""
    @FocusState private var renameFocused: Bool
    @StateObject private var menus = LaneMenuPresentation()
    @State private var savingWorkspace = false
    @State private var workspaceName = ""
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
        _filterIdle = AppStorage(wrappedValue: false, keys.filterIdle)
        _filterUnread = AppStorage(wrappedValue: false, keys.filterUnread)
        let shape = store.sidebarDefaults
        _showsHeadings = AppStorage(wrappedValue: shape.headings, keys.showsSectionHeadings)
        _showsIcons = AppStorage(wrappedValue: shape.icons, keys.showsLaneIcons)
        _showsPullRequests = AppStorage(wrappedValue: shape.pullRequests, keys.showsPullRequestPills)
        _parallelPlacement = AppStorage(wrappedValue: shape.parallel.rawValue, keys.parallelSessions)
    }

    init(store: AgentLaneStore, labels: AgentsModeLabels, inDock: Bool, @ViewBuilder accessory: () -> Accessory) {
        self.init(store: store, labels: labels, accessory: accessory)
        self.inDock = inDock
    }

    public var body: some View {
        // Read once for the whole list; every header and row uses this copy.
        let snapshot = store.listSnapshot
        let flat = isFlat(snapshot)
        let stages = store.laneLoadStages
        List(selection: selectionBinding) {
            // Every group with a heading folds the same way. The header draws its own chevron, always shown, instead of the
            // sidebar's, which appears only under the pointer and moves the
            // header's buttons when it does.
            // With section headings off, or only one section, the lanes are
            // one list with no heading; Pinned and Detached keep theirs. The
            // lanes in no section never have a heading: they lead the list,
            // above the first section.
            ForEach(displayedGroups(snapshot, flat: flat)) { group in
                if flat || group.section == nil, !group.isPinned, !group.isDetached {
                    Section { rows(group, numbers: snapshot.shortcutNumbers, stages: stages) }
                } else {
                    Section {
                        if isExpanded(group) { rows(group, numbers: snapshot.shortcutNumbers, stages: stages) }
                    } header: {
                        sectionHeader(group, snapshot: snapshot)
                    }
                    .collapsible(false)
                }
            }
        }
        .listStyle(.sidebar)
        // The Reopen As keys act on the selected lane while the list has
        // the keyboard, ahead of any app shortcut on the same keys.
        .background(LaneListKeys(store: store))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let usage = store.usage {
                VStack(spacing: 0) {
                    Divider()
                    AgentUsageMeter(model: usage)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .background(inDock ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
            }
        }
        .modifier(LaneMenuSheets(store: store, presentation: menus))
        .alert("Save Lanes as Workspace", isPresented: $savingWorkspace) {
            TextField("Name", text: $workspaceName)
            Button("Save") { store.saveWorkspace(named: workspaceName.trimmingCharacters(in: .whitespaces)) }
                .disabled(workspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the \(labels.laneNoun)s you opened, with their sections. A workspace with the same name is replaced.")
        }
        .alert("Message", isPresented: Binding(get: { store.messageAlertTarget != nil },
                                               set: { if !$0 { store.messageAlertTarget = nil } })) {
            TextField("Message", text: $message)
            Button("Send") {
                let text = message
                if let id = store.messageAlertTarget, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Task { await store.message(text, to: id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Typed into \(store.messageAlertTarget.flatMap { store.sessions[$0]?.title } ?? "the agent") and sent. A \(labels.laneNoun) not attached here is attached in the background first. If nothing takes it, it goes on the clipboard instead.")
        }
        .onChange(of: store.messageAlertTarget) { if store.messageAlertTarget != nil { message = "" } }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search \(labels.laneNoun)s")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                filterBar(progress: store.laneLoadProgress(stages))
                    .padding(.horizontal, 10)
                    .frame(height: AgentsModeMetrics.headerRowHeight)
                Divider()
            }
            // The bar material, as a standard sidebar header has, so rows
            // scroll under it and do not show through.
            .background(.bar)
            .onGeometryChange(for: CGFloat.self) { ($0.frame(in: .global).maxY * 2).rounded() / 2 } action: {
                if store.sidebarHeaderBottom != $0 { store.sidebarHeaderBottom = $0 }
            }
            .onDisappear { store.sidebarHeaderBottom = nil }
        }
        .contextMenu(forSelectionType: AgentLane.ID.self) { ids in
            if let id = ids.first, let session = store.sessions[id] {
                LaneContextMenu(store: store, session: session, presentation: menus, rowActions: rowActions)
            }
        } primaryAction: { ids in
            if let id = ids.first { store.open(id) }
        }
        .onDeleteCommand {
            if !store.isHomeShown, let id = store.selectedID, store.selected?.lane.isClosable == true { store.close(id) }
        }
        // Escape leaves the lane for All Agents, as a list's empty selection.
        .onExitCommand { store.showHome() }
        // A filter that would leave the list empty turns itself off; only a
        // search that matches nothing leaves the Show All overlay.
        .onChange(of: statusFilteredCount) { settleFilters(newest: nil) }
        .onChange(of: searchText) {
            store.displayedSidebarSearch = searchText
            // Typing a search searches every lane, so the status chips go off.
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { dropStatusFilters() }
        }
        .onAppear { settleFilters(newest: nil) }
        .overlay {
            if visibleLanes.isEmpty, !store.listedLanes.isEmpty {
                VStack(spacing: 6) {
                    Text("No Matching \(labels.listTitle)").font(.callout).foregroundStyle(.secondary)
                    Button("Show All", action: clearFilters).controlSize(.small)
                }
            }
        }
    }

    private var sessions: [AgentLaneSession] { store.listedLanes.compactMap { store.sessions[$0.id] } }

    @ViewBuilder
    private func rows(_ group: LaneGroup, numbers: [AgentLane.ID: Int],
                      stages: [AgentLane.ID: LaneLoadStage]) -> some View {
        ForEach(group.lanes) { lane in
            if let session = store.session(for: lane) {
                let look = store.rowIcon(for: session)
                LaneRow(session: session,
                        shortcutNumber: numbers[lane.id],
                        loadStage: stages[lane.id],
                        isSplit: lane.id == store.splitID,
                        style: store.configuration.rowStyle,
                        icon: look.icon, tintHex: look.tintHex, showsIcon: showsIcons, showsPullRequests: showsPullRequests,
                        isNested: parallelPlacement == ParallelSessionPlacement.nested.rawValue
                            && !group.isDetached && store.parallelOwner(of: lane.id) != nil)
                    .tag(lane.id)
                    // A found session follows its folder's row, as a row of
                    // its own with that row's icon (or indented under it,
                    // if the person chose that); it moves once adopted.
                    .moveDisabled(store.isDetached(lane.id))
            }
        }
        .onMove { from, to in move(in: group, from: from, to: to) }
    }

    /// Whether the lanes show as one list with no section headings: the
    /// app turned them off, or there is only one section.
    private func isFlat(_ snapshot: AgentLaneStore.ListSnapshot) -> Bool {
        Self.isFlat(snapshot, showsHeadings: showsHeadings)
    }

    static func isFlat(_ snapshot: AgentLaneStore.ListSnapshot, showsHeadings: Bool) -> Bool {
        !showsHeadings || snapshot.regularGroupCount <= 1
    }

    /// ``visibleGroups``, with the sections run together into one headless
    /// group when the list is flat.
    private func displayedGroups(_ snapshot: AgentLaneStore.ListSnapshot, flat: Bool) -> [LaneGroup] {
        Self.displayedGroups(snapshot, flat: flat, visible: Set(visibleLanes.map(\.id)), filtering: isFiltering)
    }

    static func displayedGroups(_ snapshot: AgentLaneStore.ListSnapshot, flat: Bool, visible: Set<AgentLane.ID>,
                                filtering: Bool) -> [LaneGroup] {
        let groups = visibleGroups(snapshot, visible: visible, filtering: filtering)
        guard flat else { return groups }
        let regular = groups.filter { !$0.isPinned && !$0.isDetached }
        var out = groups.filter(\.isPinned)
        let lanes = regular.flatMap(\.lanes)
        if !regular.isEmpty { out.append(LaneGroup(section: nil, lanes: lanes)) }
        out += groups.filter(\.isDetached)
        return out
    }

    /// The groups with only the lanes the search and filters let through.
    /// While searching every group is shown open, so a match is never hidden.
    static func visibleGroups(_ snapshot: AgentLaneStore.ListSnapshot, visible: Set<AgentLane.ID>,
                              filtering: Bool) -> [LaneGroup] {
        snapshot.groups.compactMap { group in
            var group = group
            group.lanes = group.lanes.filter { visible.contains($0.id) }
            if filtering, group.lanes.isEmpty { return nil }
            return group
        }
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !activeFilters.isEmpty
    }

    /// Open while searching or filtering, so a match is never hidden; the
    /// saved fold is left as it was and comes back when the search ends.
    private func isExpanded(_ group: LaneGroup) -> Bool {
        isFiltering || !store.layout.collapsed.contains(group.collapseKey)
    }

    /// Fold or open a group; with Option held, every group, as an Option-click
    /// on a disclosure triangle does elsewhere on the Mac.
    private func toggleExpanded(_ group: LaneGroup) {
        guard !isFiltering else { return }
        let open = !isExpanded(group)
        withAnimation(.easeInOut(duration: 0.15)) {
            if NSEvent.modifierFlags.contains(.option) {
                store.setAllCollapsed(!open)
            } else {
                store.toggleCollapsed(group.collapseKey)
            }
        }
    }

    private func beginRenaming(_ name: String) {
        sectionName = name
        renaming = name
    }

    /// Return, or leaving the field, keeps the name; ⎋ puts it back.
    private func commitRename() {
        guard let old = renaming else { return }
        renaming = nil
        store.renameSection(old, to: sectionName)
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
    private func sectionHeader(_ group: LaneGroup, snapshot: AgentLaneStore.ListSnapshot) -> some View {
        let title = group.title ?? labels.listTitle
        let movable = group.section != nil && !group.isPinned && !group.isDetached
        let expanded = isExpanded(group)
        HStack(spacing: 4) {
            SectionDisclosure(isExpanded: expanded, title: title, isEnabled: !isFiltering) {
                toggleExpanded(group)
            }
            if movable, let name = group.section, renaming == name {
                TextField("Section Name", text: $sectionName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = nil }
                    .onAppear { DispatchQueue.main.async { renameFocused = true } }
                    .onChange(of: renameFocused) { if !renameFocused { commitRename() } }
                    .accessibilityLabel("Section name")
            } else {
                Text(title)
            }
            Spacer(minLength: 4)
            if store.canAddLane(to: group) {
                Menu {
                    newLaneItems(group)
                } label: {
                    Label("New \(labels.laneNoun.capitalized) in \(title)", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Start a \(labels.laneNoun) in \(title): pick an agent, then a folder")
                .accessibilityLabel("New \(labels.laneNoun) in \(title)")
            }
        }
        .modifier(SectionDragging(name: movable ? group.section : nil, store: store))
        .contextMenu {
            if group.isDetached {
                Button("Look for Detached Sessions Again") { store.sweepForDetachedSessions() }
                Divider()
            } else {
                Menu("New \(labels.laneNoun.capitalized) in Section") { newLaneItems(group) }
                Divider()
                if movable, let name = group.section {
                    Button("Rename Section") { beginRenaming(name) }
                    Button("Move Section Up") { store.moveSection(name, by: -1) }
                        .disabled(snapshot.sectionNames.first == name)
                    Button("Move Section Down") { store.moveSection(name, by: 1) }
                        .disabled(snapshot.sectionNames.last == name)
                    Button("Remove Section") { store.removeSection(name) }
                    Divider()
                }
            }
            Button("New Section…") { menus.newSection() }
            Divider()
            Button("Collapse Other Sections") { store.collapseOtherSections(than: group) }
                .disabled(!(snapshot.groups.count > 1
                    && snapshot.collapseKeys.subtracting([group.collapseKey]) != store.layout.collapsed))
            Button("Collapse All") { store.setAllCollapsed(true) }
            Button("Expand All") { store.setAllCollapsed(false) }
        }
    }

    /// One item per agent; each asks for a folder, then starts the lane in
    /// `group` and selects it.
    @ViewBuilder
    private func newLaneItems(_ group: LaneGroup) -> some View {
        NewSessionDefaultItems(store: store) { Task { await store.newSessionLane(in: group) } }
        ForEach(store.availableBackends, id: \.id) { backend in
            Button("\(backend.displayName)…") {
                Task { await store.newLane(in: group, backendID: backend.id) }
            }
        }
    }

    private var selectionBinding: Binding<AgentLane.ID?> {
        Binding(get: { store.isHomeShown ? nil : store.selectedID },
                set: { id in
                    // A click hands the keyboard to the lane's terminal so
                    // typing goes straight to the agent. Moving through the
                    // list with the arrow keys attaches each lane but leaves
                    // the keyboard in the list; Return then hands it over.
                    let fromKeyboard = NSApp.currentEvent?.type == .keyDown
                    if let id { store.open(id, focus: !fromKeyboard) }
                })
    }

    /// The lanes the search and status filters let through. A search that
    /// matches a section's name lets all of that section's lanes through.
    private var visibleLanes: [AgentLane] {
        Self.visibleLanes(store: store, query: searchText, filters: activeFilters)
    }

    /// A search is made across all lanes, so it sets the status filters aside;
    /// one that finds nothing shows every lane, as Show All does, without
    /// the person having to ask: the search text stays, and the list comes back
    /// narrowed again as soon as the text matches something.
    static func visibleLanes(store: AgentLaneStore, query: String, filters: Set<LaneStatusFilter>) -> [AgentLane] {
        let found = matchingLanes(store: store, query: query, filters: filters)
        guard found.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return found }
        // A search the status filters hide drops the filters and keeps the search.
        if !filters.isEmpty {
            let anywhere = matchingLanes(store: store, query: query, filters: [])
            if !anywhere.isEmpty { return anywhere }
        }
        return store.listedLanes.filter { store.session(for: $0) != nil }
    }

    private static func matchingLanes(store: AgentLaneStore, query rawQuery: String,
                                      filters: Set<LaneStatusFilter>) -> [AgentLane] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let sectionHits = query.isEmpty ? [] : lanesInSections(matching: query, groups: store.groups,
                                                               section: store.layout.section(of:))
        let selected = store.selectedID
        return store.listedLanes.filter { lane in
            guard let session = store.session(for: lane) else { return false }
            if !query.isEmpty, !sectionHits.contains(lane.id), !matches(session, query: query) { return false }
            var state = filterState(session)
            // Opening an unread row reads it; it stays in the Unread list
            // while it is the one open, rather than vanishing under the click.
            if lane.id == selected { state.unread = true }
            return filters.allSatisfy { $0.admits(state) }
        }
    }

    private var activeFilters: Set<LaneStatusFilter> {
        var on: Set<LaneStatusFilter> = []
        if filterAttached { on.insert(.active) }
        if filterRunning { on.insert(.running) }
        if filterNeedsYou { on.insert(.needsYou) }
        if filterIdle { on.insert(.idle) }
        if filterUnread { on.insert(.unread) }
        return on
    }

    private func setFilter(_ filter: LaneStatusFilter, _ on: Bool) {
        switch filter {
        case .active: filterAttached = on
        case .running: filterRunning = on
        case .needsYou: filterNeedsYou = on
        case .idle: filterIdle = on
        case .unread: filterUnread = on
        }
    }

    /// How many lanes the status filters alone let through.
    private var statusFilteredCount: Int {
        let filters = activeFilters
        return sessions.filter { s in filters.allSatisfy { $0.admits(Self.filterState(s)) } }.count
    }

    /// What the status filters look at in a row.
    static func filterState(_ session: AgentLaneSession) -> LaneStatusFilter.Lane {
        .init(isActive: session.isActive, status: session.status, unread: session.needsAttention)
    }

    /// Turn off whatever filters would leave nothing to show.
    private func settleFilters(newest: LaneStatusFilter?) {
        let on = activeFilters
        guard !on.isEmpty else { return }
        // While the lanes are still loading, an empty list says nothing yet:
        // Active, on at launch, stays on until the hosts have answered.
        guard newest != nil || !(store.homeLoading.isLoading || store.laneLoadProgress(store.laneLoadStages).isLoading)
        else { return }
        let kept = LaneStatusFilter.settled(on, newest: newest, lanes: sessions.map(Self.filterState))
        for filter in on.subtracting(kept) { setFilter(filter, false) }
    }

    private func filterBinding(_ filter: LaneStatusFilter) -> Binding<Bool> {
        Binding(get: { activeFilters.contains(filter) },
                set: { on in
                    setFilter(filter, on)
                    if on {
                        // A chip starts from the whole list, not from a search.
                        searchText = ""
                        settleFilters(newest: filter)
                    }
                })
    }

    /// Whether a search finds the lane: by its name, folder, summary or the
    /// person's recent prompts in it.
    static func matches(_ session: AgentLaneSession, query: String) -> Bool {
        matches(query: query, in: [session.title, session.lane.path, session.summary ?? ""] + session.recentPrompts)
    }

    /// The lanes a search finds by the name of their section: every lane of
    /// a group whose title matches, and pinned lanes by the section they
    /// belong to.
    static func lanesInSections(matching query: String, groups: [LaneGroup],
                                section: (AgentLane) -> String?) -> Set<AgentLane.ID> {
        var hits: Set<AgentLane.ID> = []
        for group in groups {
            for lane in group.lanes {
                let names = [group.title, section(lane)].compactMap { $0 }
                if !names.isEmpty, matches(query: query, in: names) { hits.insert(lane.id) }
            }
        }
        return hits
    }

    nonisolated static func matches(query: String, in fields: [String]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return fields.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func wantsYou(_ status: LaneDisplayStatus) -> Bool { LaneStatusFilter.wantsYou(status) }

    private func dropStatusFilters() {
        for filter in LaneStatusFilter.allCases { setFilter(filter, false) }
    }

    private func clearFilters() {
        dropStatusFilters()
        searchText = ""
    }

    /// Status toggles with their counts.
    private func filterBar(progress: LaneLoadProgress) -> some View {
        let all = sessions
        return HStack(spacing: 2) {
            // Each half keeps its full size, so no count or button is ever
            // cut; the list's minimum width is what the two need.
            HStack(spacing: 2) {
                ForEach(LaneStatusFilter.allCases, id: \.self) { filter in
                    LaneFilterToggle(symbol: filter.symbol, symbolScale: filter.symbolScale, title: filter.title,
                                     help: filter.help(noun: labels.laneNoun),
                                     count: all.filter { filter.admits(Self.filterState($0)) }.count,
                                     progress: progress,
                                     isOn: filterBinding(filter))
                }
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipsWidth = $0; reportWidth() }
            Spacer(minLength: 0)
            filterBarControls
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlsWidth = $0; reportWidth() }
        }
    }

    /// Tell the store how wide the list must be for the bar above it:
    /// both halves, the gap between them, the bar's padding and some room.
    private func reportWidth() {
        let needed = AgentLaneStore.sidebarMinimumWidth(chips: chipsWidth, controls: controlsWidth)
        if store.sidebarMinimumWidth != needed { store.sidebarMinimumWidth = needed }
    }

    /// The list's own controls at the right of the filter bar.
    @ViewBuilder
    private var filterBarControls: some View {
        HStack(spacing: 2) {
            // The app's accessory and the + menu are the whole list's, so
            // they sit here rather than on a section's heading; each
            // section's heading keeps its own + for that section.
            accessory
            ForEach(store.accessoryLanes) { lane in
                if let accessory = lane.accessory { AgentAccessoryLaneButton(store: store, lane: lane, accessory: accessory) }
            }
            Menu {
                newLaneItems(LaneGroup(section: nil, lanes: []))
            } label: {
                Label("New \(labels.laneNoun.capitalized)", systemImage: "plus").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Start a \(labels.laneNoun): pick an agent, then a folder")
            .accessibilityLabel("New \(labels.laneNoun)")
            // The inbox sits with the other list controls at the top; the
            // foot belongs to the usage meter.
            if let inboxID = store.configuration.inboxWindowID {
                AgentInboxButton(store: store, windowID: inboxID)
            }
            Menu {
                Picker("Sort", selection: Binding(get: { store.layout.sort }, set: { store.setSort($0) })) {
                    ForEach(LaneLayout.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Section("Show Only") {
                    ForEach(LaneStatusFilter.allCases, id: \.self) { filter in
                        Toggle(filter.title, isOn: filterBinding(filter))
                    }
                }
                Divider()
                Button("New Section…") { menus.newSection() }
                Button("Collapse Other Sections") { store.collapseOtherSectionsThanSelected() }
                    .disabled(store.selectedID.flatMap { store.group(containing: $0) }
                        .map { !store.canCollapseOtherSections(than: $0) } ?? true)
                Button("Collapse All") { store.setAllCollapsed(true) }
                Button("Expand All") { store.setAllCollapsed(false) }
                if store.configuration.workspaceFile != nil {
                    Divider()
                    Menu("Workspaces") {
                        AgentWorkspaceMenu(store: store) { workspaceName = ""; savingWorkspace = true }
                    }
                }
            } label: {
                // The Mac's filter symbol, circled while a Show Only filter
                // is on, as Mail and Finder mark a filtered list.
                Label("Sort and Filter", systemImage: activeFilters.isEmpty ? "line.3.horizontal.decrease"
                                                                           : "line.3.horizontal.decrease.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(activeFilters.isEmpty ? "Sort or filter the list, or add and fold sections"
                                        : "Sort or filter the list, or add and fold sections (a filter is on)")
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
    let labels: AgentsModeLabels
    let rowActions: [LaneAction]

    /// `labels` and `rowActions` are All Agents' (``AgentHomeView``), shown here
    /// while ``AgentLaneStore/isHomeShown``.
    public init(store: AgentLaneStore, labels: AgentsModeLabels = .init(), rowActions: [LaneAction] = [],
                @ViewBuilder empty: () -> Empty) {
        self.store = store
        self.labels = labels
        self.rowActions = rowActions
        self.empty = empty()
    }

    public var body: some View {
        Group {
            if store.lanes.isEmpty {
                empty
            } else if store.isHomeShown {
                AgentHomeView(store: store, labels: labels, rowActions: rowActions)
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
            store.openSelectedOnShow()
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
                .navigationSplitViewColumnWidth(min: store.sidebarMinimumWidth, ideal: store.sidebarMinimumWidth,
                                                max: max(520, store.sidebarMinimumWidth))
        } detail: {
            AgentLaneDetail(store: store, labels: labels, rowActions: rowActions) { empty }
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
                TerminalHost(session: session, store: store)
                    .id("\(session.id)#\(session.generation)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.launchAttachPending == session.id {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Nothing runs for this lane yet: say so and offer to start
                // it, rather than a spinner that never ends.
                VStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(session.title).font(.title3)
                    Text("Not attached").foregroundStyle(.secondary)
                    Button("Start Session") { store.open(session.id, focus: true) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
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

/// Adopt ▸ No Section, then each section: the same submenu on a Detached
/// row and in the menu bar.
struct DetachedAdoptMenu: View {
    @ObservedObject var store: AgentLaneStore
    let id: AgentLane.ID?
    var title = "Adopt Into Section"

    var body: some View {
        Menu(title) {
            Button("No Section") { if let id { store.adopt(id, into: nil) } }
            if !store.sectionNames.isEmpty { Divider() }
            ForEach(store.sectionNames, id: \.self) { name in
                Button(name) { if let id { store.adopt(id, into: name) } }
            }
        }
        .disabled(id.map { !store.isDetached($0) } ?? true)
        .help("Keep this session as a lane of your own, in a section")
    }
}

struct LaneRow: View {
    @ObservedObject var session: AgentLaneSession
    /// The ⌘ number that reaches the row: pinned rows only.
    let shortcutNumber: Int?
    /// What the row is waiting on while the window fills in.
    var loadStage: LaneLoadStage? = nil
    let isSplit: Bool
    var style: LaneRowStyle = .standard
    /// The icon to draw, when it is not the session's own: a parallel
    /// session draws its lane's (``AgentLaneStore/rowIcon(for:)``).
    var icon: LaneIcon? = nil
    var tintHex: String? = nil
    /// Off, the row shows its status dot alone.
    var showsIcon = true
    var showsPullRequests = false
    /// Indented under the row above: a parallel session, when the person
    /// chose ``ParallelSessionPlacement/nested``.
    var isNested = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsIcon {
                LaneIconView(icon: icon ?? session.icon, tintHex: icon == nil ? session.tintHex : tintHex, size: 16)
                    .frame(width: 20)
                    .overlay(alignment: .bottomTrailing) { statusDot.offset(x: 3, y: 3) }
                    .padding(.top, 1)
            } else {
                statusDot
                    .frame(width: 10, height: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.title)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 2)
                    trailingIndicators
                }
                let detail = detailText
                let status = statusLine
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !status.isEmpty {
                    statusText(status)
                }
                let carriesStatus = detail != nil && !status.isEmpty
                if carriesStatus || hasPullRequestPills {
                    HStack(spacing: 4) {
                        if hasPullRequestPills {
                            pullRequestPills.layoutPriority(1)
                        }
                        if carriesStatus {
                            statusText(status).frame(minWidth: 24, alignment: .leading)
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, isNested ? 14 : 0)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.title)
        .accessibilityValue(accessibilityValue)
    }

    /// The status and branch: one caption line, cut from the front so the
    /// branch stays readable.
    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.head)
    }

    /// The small marks that stay beside the title: progress, ports, the
    /// unread dot and the row's ⌘ number.
    @ViewBuilder
    private var trailingIndicators: some View {
        if let loadStage { LaneLoadIndicator(stage: loadStage) }
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
        if let shortcutNumber {
            Text("⌘\(shortcutNumber)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hasPullRequestPills: Bool {
        showsPullRequests && !session.displayedPullRequests.isEmpty || session.rowMetadata.pullRequest != nil
    }

    /// The pull request pills on their own line under the title: as many of
    /// the newest as fit, and a count of the rest.
    @ViewBuilder
    private var pullRequestPills: some View {
        let pullRequests = session.displayedPullRequests
        if !pullRequests.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: min(pullRequests.count, Self.rowChipLimit), through: 1, by: -1)), id: \.self) { shown in
                    pills(Array(pullRequests.suffix(shown)), hidden: pullRequests.count - shown)
                }
                overflowCount(pullRequests.count)
            }
        } else if let pr = session.rowMetadata.pullRequest {
            Text("#\(pr.number)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 5)
                .background(Capsule().fill(Self.color(for: pr.state).opacity(0.18)))
                .foregroundStyle(Self.color(for: pr.state))
                .help("Pull request #\(pr.number), \(pr.state.rawValue)")
                .accessibilityLabel("Pull request \(pr.number), \(pr.state.rawValue)")
        }
    }

    private func pills(_ shown: [LanePullRequest], hidden: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(shown) { PullRequestBadge(pullRequest: $0).fixedSize() }
            if hidden > 0 { overflowCount(hidden) }
        }
    }

    private func overflowCount(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    /// The summary the row leads with, in the summary-first style.
    private var leadingSummary: String? {
        guard style == .summaryFirst, let summary = session.summary, !summary.isEmpty else { return nil }
        return summary
    }

    /// The most pull request chips a row shows; the rest, and any that do
    /// not fit the width, are counted.
    static let rowChipLimit = 4

    private var accessibilityValue: String {
        let status = session.isOrphan ? "Running, nothing attached"
            : session.needsAttention ? "\(session.status.title), new" : session.status.title
        var parts = [loadStage?.title ?? status]
        if let notice = session.renameNotice { parts.append(notice) }
        if let summary = session.summary, !summary.isEmpty { parts.append(summary) }
        parts += session.displayedPullRequests.map(\.accessibilityDescription)
        return parts.joined(separator: ", ")
    }

    private var isActive: Bool {
        switch session.status {
        case .running, .waitingForInput, .permissionRequested: true
        default: false
        }
    }

    /// The agent's own words for the row: its note, or the summary once it
    /// stops working (always, in the summary-first style). Up to two lines.
    private var detailText: String? {
        if session.renameNotice != nil { return nil }
        if let text = session.note?.text, !text.isEmpty { return text }
        if let summary = leadingSummary { return summary }
        if let summary = session.summary, !summary.isEmpty, session.status != .running { return summary }
        return nil
    }

    /// The compact status and branch: on the line under the title when the
    /// row has no summary, beside the pills when it does.
    private var statusLine: String {
        if let notice = session.renameNotice { return notice }
        let base = detailText == nil || loadStage != nil ? statusSubtitle : ""
        guard let branch = session.rowMetadata.branch else { return base }
        return base.isEmpty ? branch : base + " · " + branch
    }

    private var statusSubtitle: String {
        if let loadStage { return loadStage.title }
        if session.isOrphan, !session.isAttached { return "Running, nothing attached" }
        if session.lane.isClosable, session.status == .attached || session.status == .detached {
            return session.shortDirectory
        }
        // Every row says what it is doing, a lane that needs the person
        // too, beside its dot.
        let title = session.status.title
        if isSplit { return title.isEmpty ? "split" : title + " · split" }
        return title
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
        if let summary = session.summary, !summary.isEmpty { lines.append(summary) }
        if !session.recentPrompts.isEmpty {
            lines.append("Recent requests:")
            lines.append(contentsOf: session.recentPrompts.map { "• " + String($0.prefix(140)) })
        }
        if let note = session.note {
            if let progress = note.progress { lines.append("\(Int(progress * 100))% done") }
            lines.append(contentsOf: note.log.suffix(5))
        }
        if let message = session.record?.message, !message.isEmpty { lines.append(message) }
        let pullRequests = session.displayedPullRequests
        if !pullRequests.isEmpty {
            lines.append("Pull requests:")
            lines.append(contentsOf: pullRequests.map { "• " + $0.menuTitle })
        }
        if let reply = Self.hoverReply(session.lastReply) {
            lines.append("Last reply:")
            lines.append(reply)
        }
        return lines.joined(separator: "\n")
    }

    /// The agent's last reply for the hover: one paragraph, cut short.
    static func hoverReply(_ reply: String?, limit: Int = 400) -> String? {
        guard let reply else { return nil }
        let flat = reply.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
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

/// The status chips above the lane list. Several on at once must all hold.
enum LaneStatusFilter: String, CaseIterable, Sendable {
    case active, running, needsYou, idle, unread

    /// What a filter looks at in one row.
    struct Lane: Sendable {
        var isActive: Bool
        var status: LaneDisplayStatus
        /// The row has news the person has not seen: its blue dot.
        var unread = false
    }

    static func wantsYou(_ status: LaneDisplayStatus) -> Bool {
        status == .waitingForInput || status == .permissionRequested
    }

    /// Whether a lane with this state passes the filter. Idle is a lane
    /// that is alive (attached here or running elsewhere) with an agent that
    /// is neither working nor waiting for the person.
    func admits(isActive: Bool, status: LaneDisplayStatus, unread: Bool = false) -> Bool {
        switch self {
        case .active: isActive
        case .running: status == .running
        case .needsYou: Self.wantsYou(status)
        case .idle: isActive && status != .running && !Self.wantsYou(status)
        case .unread: unread
        }
    }

    func admits(_ lane: Lane) -> Bool { admits(isActive: lane.isActive, status: lane.status, unread: lane.unread) }

    /// The filters to keep on so the list is not left empty: all of `on`
    /// when some lane passes them, else only `newest` (the chip just turned
    /// on) when some lane passes it, else none.
    static func settled(_ on: Set<LaneStatusFilter>, newest: LaneStatusFilter?,
                        lanes: [Lane]) -> Set<LaneStatusFilter> {
        func passes(_ filters: Set<LaneStatusFilter>) -> Bool {
            lanes.contains { lane in filters.allSatisfy { $0.admits(lane) } }
        }
        if on.isEmpty || passes(on) { return on }
        if let newest, on.contains(newest), passes([newest]) { return [newest] }
        return []
    }

    var title: String {
        switch self {
        case .active: "Active"
        case .running: "Running"
        case .needsYou: "Needs You"
        case .idle: "Idle"
        case .unread: "Unread"
        }
    }

    var symbol: String {
        switch self {
        case .active: "circle.fill"
        case .running: "bolt.fill"
        case .needsYou: "hand.raised.fill"
        case .idle: "moon.fill"
        case .unread: "bell.badge.fill"
        }
    }

    var symbolScale: CGFloat { self == .active ? 0.7 : 1 }

    func help(noun: String) -> String {
        switch self {
        case .active: "Show only \(noun)s attached here or running elsewhere"
        case .running: "Show only \(noun)s whose agent is working"
        case .needsYou: "Show only \(noun)s waiting for input or permission"
        case .idle: "Show only \(noun)s that are open but not working or waiting for you"
        case .unread: "Show only \(noun)s with news you have not seen yet"
        }
    }
}

/// A section header's chevron: always shown, in a fixed frame, so the header
/// never moves as the pointer comes and goes. Down while the section is open.
struct SectionDisclosure: View {
    let isExpanded: Bool
    let title: String
    var isEnabled = true
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isExpanded ? "Collapse \(title) (Option-click for every section)"
                         : "Expand \(title) (Option-click for every section)")
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Collapses the section" : "Expands the section")
    }
}

/// Drag a section's header onto another's to put it before that one.
/// Move Section Up and Down in the header's menu do the same from the
/// keyboard.
private struct SectionDragging: ViewModifier {
    let name: String?
    let store: AgentLaneStore
    @State private var targeted = false

    static let prefix = "agentsmate-section:"

    func body(content: Content) -> some View {
        if let name {
            content
                .draggable(Self.prefix + name) { Text(name).padding(4) }
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, item.hasPrefix(Self.prefix) else { return false }
                    let moved = String(item.dropFirst(Self.prefix.count))
                    guard moved != name else { return false }
                    store.moveSection(moved, before: name)
                    return true
                } isTargeted: { targeted = $0 }
                .overlay(alignment: .top) {
                    if targeted { Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -3) }
                }
        } else {
            content
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
    var progress = LaneLoadProgress(finished: 0, total: 0)
    @Binding var isOn: Bool
    @State private var hovered = false

    private var isDisabled: Bool { count == 0 && !isOn }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 10 * symbolScale, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                // Room for two digits whatever the count, so the bar is as
                // wide at 5 as at 55 and the list's minimum covers both.
                ZStack(alignment: .leading) {
                    Text("88").hidden().accessibilityHidden(true)
                    Text(progress.display(count)).foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
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
        .accessibilityValue(progress.accessibleCount(count))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Takes the Reopen As keys while the lane list has the keyboard. It sits
/// behind the list, filling the same frame, and answers a key press only when
/// the focused view is a table inside that frame — the list itself, not its
/// search field or the window's other content.
struct LaneListKeys: NSViewRepresentable {
    let store: AgentLaneStore

    func makeNSView(context: Context) -> LaneListKeysView {
        let view = LaneListKeysView()
        view.store = store
        return view
    }

    func updateNSView(_ view: LaneListKeysView, context: Context) { view.store = store }
}

final class LaneListKeysView: NSView {
    weak var store: AgentLaneStore?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        store?.keyboard.register(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether the window's focused view is the list this view sits behind.
    var listHasKeyboard: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor,
              let focused = window.firstResponder as? NSTableView else { return false }
        let list = (focused.enclosingScrollView ?? focused).convert((focused.enclosingScrollView ?? focused).bounds, to: nil)
        let mine = convert(bounds, to: nil)
        return mine.insetBy(dx: -2, dy: -2).contains(list) || list.insetBy(dx: -2, dy: -2).contains(mine)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let store, event.window === window, listHasKeyboard,
              let kind = store.shortcuts.reopenKind(for: event),
              store.configuration.shortcuts.contains(.reopen) else { return false }
        return store.reopenSelected(kind: kind)
    }
}

/// Hosts a session's terminal and hands it keyboard focus once it is
/// actually in a window — focus asked for before then is silently dropped.
final class TerminalContainer: NSView {
    var session: AgentLaneSession?
    weak var store: AgentLaneStore?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        store?.keyboard.watch(window)
        focusIfWanted()
    }

    func focusIfWanted() {
        guard let session, session.wantsFocus, let window else { return }
        // Deferred: this runs inside a SwiftUI update, which must not publish.
        DispatchQueue.main.async {
            session.wantsFocus = false
            window.makeFirstResponder(session.view)
            self.store?.updateLanesHaveKeyboard()
        }
    }
}

/// The terminal drawn by a session, hosted in SwiftUI. The session owns the
/// view, so the same NSView is re-hosted when the pane reappears.
struct TerminalHost: NSViewRepresentable {
    @ObservedObject var session: AgentLaneSession
    let store: AgentLaneStore

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        container.store = store
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


/// The button for a lane the app lists nowhere else (``AgentLane/Accessory``):
/// it sits in the filter bar, opens the lane in the detail pane and shows as
/// selected while that pane is showing. A plain borderless button, as its
/// neighbours are, tinted only while selected.
struct AgentAccessoryLaneButton: View {
    @ObservedObject var store: AgentLaneStore
    let lane: AgentLane
    let accessory: AgentLane.Accessory

    var body: some View {
        let selected = store.isShowingAccessory(lane.id)
        Button { store.open(lane.id) } label: {
            LaneIconView(icon: accessory.icon, tint: selected ? .accentColor : .primary, size: 14)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(accessory.label)
        .accessibilityLabel(accessory.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
