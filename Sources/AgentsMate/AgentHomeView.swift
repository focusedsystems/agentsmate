import SwiftUI
import AppKit

/// All Agents: every active session in the app's lanes on one board, a
/// column each for Needs You, Working and Idle & Done. ``AgentLaneDetail``
/// shows it in place of the terminal while ``AgentLaneStore/isHomeShown``;
/// an app with its own layout can show it anywhere.
///
/// Click a card, or move to it with the arrow keys and press Return, to open
/// its lane exactly as the sidebar does. Typing filters the board; the
/// sidebar's status filters apply here too. It fills in as hosts answer and
/// never waits on them.
public struct AgentHomeView: View {
    @ObservedObject var store: AgentLaneStore
    let labels: AgentsModeLabels
    let rowActions: [LaneAction]

    @State private var selection: AgentLane.ID?
    @State private var query = ""
    @FocusState private var boardFocused: Bool
    @State private var searchFocused = false

    @AppStorage private var filterAttached: Bool
    @AppStorage private var filterRunning: Bool
    @AppStorage private var filterNeedsYou: Bool
    @AppStorage private var filterIdle: Bool
    @AppStorage private var filterUnread: Bool
    @AppStorage private var showsPullRequests: Bool

    public init(store: AgentLaneStore, labels: AgentsModeLabels = .init(), rowActions: [LaneAction] = []) {
        self.store = store
        self.labels = labels
        self.rowActions = rowActions
        let keys = store.keys
        _filterAttached = AppStorage(wrappedValue: false, keys.filterOpen)
        _filterRunning = AppStorage(wrappedValue: false, keys.filterRunning)
        _filterNeedsYou = AppStorage(wrappedValue: false, keys.filterWaiting)
        _filterIdle = AppStorage(wrappedValue: false, keys.filterIdle)
        _filterUnread = AppStorage(wrappedValue: false, keys.filterUnread)
        _showsPullRequests = AppStorage(wrappedValue: store.sidebarDefaults.pullRequests, keys.showsPullRequestPills)
    }

    public var body: some View {
        // Read once per update: the grouping walks every row.
        let columns = displayedColumns
        let totals = AgentHome.totals(allGroups)
        let stages = store.laneLoadStages
        let progress = store.laneLoadProgress(stages)
        let loading = store.homeLoading
        VStack(spacing: 0) {
            header(totals, progress: progress)
                .frame(height: headerHeight, alignment: .bottom)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { headerTop = $0 }
            Divider()
            if (progress.isLoading || loading.isLoading) && !store.startsFromLiveSnapshot {
                loadingRow(loading, progress: progress)
                Divider()
                AgentHomeLoadingList(store: store, stages: stages, open: open)
            } else {
                // A host that never answered stays in view, with its Retry;
                // over the snapshot's board, so do the hosts still answering.
                if !store.unknownHosts.isEmpty || progress.isLoading || loading.isLoading {
                    loadingRow(loading, progress: progress)
                    Divider()
                }
                if columns.allSatisfy(\.items.isEmpty) {
                    emptyState
                } else {
                    board(columns)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { DispatchQueue.main.async { boardFocused = true } }
        .onChange(of: query) { store.displayedHomeSearch = query }
    }

    // MARK: Rows

    private var sessionsByID: [AgentLane.ID: AgentLaneSession] { store.sessions }

    /// Every section with every row, before search and filters: the totals.
    private var allGroups: [(section: AgentHomeSection, items: [AgentHomeItem])] {
        AgentHome.grouped(store.homeSessions.map(AgentLaneStore.homeItem))
    }

    /// The columns with only the cards the search and the sidebar's status
    /// filters let through.
    private var displayedColumns: [(section: AgentHomeSection, items: [AgentHomeItem])] {
        Self.columns(store: store, query: query, filters: activeFilters, activeOnly: filterAttached)
    }

    static func columns(store: AgentLaneStore, query: String, filters: Set<LaneStatusFilter>,
                        activeOnly: Bool) -> [(section: AgentHomeSection, items: [AgentHomeItem])] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let sessions = store.homeSessions.filter { session in
            if !text.isEmpty {
                let area = store.homeArea(of: session.lane) ?? ""
                guard AgentLaneSidebar<EmptyView>.matches(session, query: text)
                        || AgentLaneSidebar<EmptyView>.matches(query: text, in: [area]) else { return false }
            }
            let state = AgentLaneSidebar<EmptyView>.filterState(session)
            return filters.allSatisfy { $0.admits(state) }
        }
        return AgentHome.columns(sessions.map(AgentLaneStore.homeItem), includesNotRunning: !activeOnly)
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

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || !activeFilters.isEmpty
    }

    /// The board: a column per state, a card per session.
    private func board(_ columns: [(section: AgentHomeSection, items: [AgentHomeItem])]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(columns, id: \.section) { column in
                AgentHomeColumn(section: column.section, count: column.items.count, selection: selection) {
                    ForEach(column.items) { item in
                        if let session = sessionsByID[item.id] {
                            AgentHomeCard(session: session, area: store.homeArea(of: session.lane),
                                          isSelected: selection == item.id, isFocused: boardFocused,
                                          showsPullRequests: showsPullRequests,
                                          badges: store.laneBadges(for: session.lane))
                                .id(item.id)
                                .onTapGesture { open(item.id) }
                                .contextMenu {
                                    LaneContextMenu(store: store, session: session, rowActions: rowActions)
                                }
                                .accessibilityAction { open(item.id) }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($boardFocused)
        // Arrows move between cards, Return opens one, and typing filters
        // the board, as in Finder's and Mail's type-to-search fields;
        // Delete takes a character back and Escape clears it.
        .onKeyPress(phases: .down) { press in handleKey(press, columns: columns) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions by state")
    }

    /// A click opens the card's lane, as the sidebar's rows do.
    private func open(_ id: AgentLane.ID) {
        selection = id
        store.open(id)
    }

    private func handleKey(_ press: KeyPress, columns: [(section: AgentHomeSection, items: [AgentHomeItem])])
        -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let ids = columns.map { $0.items.map(\.id) }
        func go(_ move: AgentHome.Move) -> KeyPress.Result {
            selection = AgentHome.move(move, from: selection, in: ids)
            return .handled
        }
        switch press.key {
        case .upArrow: return go(.up)
        case .downArrow: return go(.down)
        case .leftArrow: return go(.left)
        case .rightArrow: return go(.right)
        case .return:
            guard let id = selection, ids.contains(where: { $0.contains(id) }) else { return .ignored }
            store.open(id)
            return .handled
        case .delete, .deleteForward:
            guard !query.isEmpty else { return .ignored }
            query.removeLast()
            return .handled
        case .escape:
            guard !query.isEmpty else { return .ignored }
            query = ""
            return .handled
        default:
            break
        }
        let chars = press.characters
        guard !chars.isEmpty, chars.unicodeScalars.allSatisfy({ Self.typeable.contains($0) }),
              !(chars == " " && query.isEmpty) else { return .ignored }
        query += chars
        return .handled
    }

    private static let typeable = CharacterSet.alphanumerics.union(.punctuationCharacters)
        .union(.symbols).union(.init(charactersIn: " "))

    // MARK: Header

    @State private var headerTop: CGFloat = 0

    /// The header runs down to the line the sidebar's header ends at, its row
    /// sitting at the bottom, so the two rows share one baseline and the two
    /// dividers one line. Its own height when the sidebar is not beside it.
    private var headerHeight: CGFloat {
        Self.headerHeight(top: headerTop, sidebarBottom: store.sidebarHeaderBottom)
    }

    static func headerHeight(top: CGFloat, sidebarBottom: CGFloat?, dividerThickness: CGFloat = 1) -> CGFloat {
        let row = AgentsModeMetrics.headerRowHeight
        guard let sidebarBottom else { return row }
        return max(row, sidebarBottom - top - dividerThickness)
    }

    private func header(_ totals: AgentHome.Totals, progress: LaneLoadProgress) -> some View {
        HStack(spacing: 14) {
            total(totals.needsYou, "need you", symbol: "hand.raised.fill", color: .orange, progress: progress)
            total(totals.working, "working", symbol: "bolt.fill", color: .green, progress: progress)
            total(totals.recent, "idle or done", symbol: "moon.fill", color: .secondary, progress: progress)
            Spacer(minLength: 8)
            showPicker
            searchField
        }
        .padding(.horizontal, 16)
        .frame(height: AgentsModeMetrics.headerRowHeight)
    }

    private func total(_ count: Int, _ noun: String, symbol: String, color: Color,
                       progress: LaneLoadProgress) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(count > 0 ? color : .secondary)
            Text(progress.display(count)).monospacedDigit().fontWeight(.medium)
            Text(noun).foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.accessibleCount(count)) \(noun)")
    }

    /// Active only, the launch default, or every lane, saved lanes with
    /// nothing running among them. The sidebar's Active filter is the same switch.
    private var showPicker: some View {
        Picker("Show", selection: $filterAttached) {
            Text("Active").tag(true)
            Text("All Lanes").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Show only the sessions that are running, or every lane, including saved lanes with nothing running")
        .accessibilityLabel("Show")
    }

    private var searchField: some View {
        AgentsSearchField(text: $query, prompt: "Filter", isFocused: $searchFocused, controlSize: .small,
                          identifier: "AgentHomeFilter",
                          onSubmit: { boardFocused = true }, onClear: { query = ""; boardFocused = true })
            .frame(width: 200)
            .help("Filter by name, folder, section, summary or your recent prompts; or just start typing on the board")
            .accessibilityLabel("Filter sessions")
    }

    /// How many lanes have loaded, and each host that was asked.
    private func loadingRow(_ loading: AgentHomeLoading, progress: LaneLoadProgress) -> some View {
        HStack(spacing: 10) {
            Text(progress.title).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            ProgressView(value: Double(progress.finished), total: Double(max(progress.total, 1)))
                .frame(maxWidth: 160)
                .accessibilityLabel("Sessions loaded")
                .accessibilityValue("\(progress.finished) of \(progress.total)")
            ForEach(loading.hosts) { host in
                HStack(spacing: 3) {
                    switch host.state {
                    case .asking: LaneLoadIndicator(stage: .checkingHost(host.name))
                    case .answered: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unreachable: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(host.name)
                    if host.state == .unreachable {
                        Button("Retry") { store.retryHost(host.name) }
                            .controlSize(.mini)
                            .accessibilityLabel("Retry \(host.name)")
                    }
                }
                .font(.caption)
                .help(host.state == .asking ? "Asking \(host.name) what it has running"
                      : host.state == .answered ? "\(host.name) answered"
                      : "\(host.name) did not answer; its sessions are unknown")
                .accessibilityElement(children: .contain)
                .accessibilityValue(host.state == .asking ? "asking" : host.state == .answered ? "answered" : "no answer")
            }
            if loading.findingSessions {
                Text("Looking for sessions…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            LaneIconView(icon: AgentsToolbar.agentsIcon, tint: .secondary, size: 32)
                .accessibilityHidden(true)
            if isFiltering, !allGroups.isEmpty {
                Text("No Matching Sessions").font(.title3)
                Button("Show All") { clearFilters() }
            } else {
                Text("No Active Sessions").font(.title3)
                Text(store.homeLoading.isLoading ? "Still asking for sessions…"
                     : "Pick a \(labels.laneNoun) in the sidebar, or start a new session.")
                    .foregroundStyle(.secondary)
                newSessionButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var newSessionButton: some View {
        let backends = store.availableBackends
        if backends.count > 1 {
            Menu("New Session") {
                NewSessionDefaultItems(store: store) {
                    Task { await store.newSessionLane(in: LaneGroup(section: nil, lanes: [])) }
                }
                ForEach(backends, id: \.id) { backend in
                    Button("\(backend.displayName)…") {
                        Task { await store.newLane(in: LaneGroup(section: nil, lanes: []), backendID: backend.id) }
                    }
                }
                OpenSessionByIDItem(store: store, section: nil)
            }
            .fixedSize()
            .controlSize(.large)
            .help(store.newSessionPlan().reason ?? "")
        } else {
            Button("New Session") {
                if let onNewLane = store.onNewLane {
                    onNewLane()
                } else {
                    Task { await store.newSessionLane(in: LaneGroup(section: nil, lanes: [])) }
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .help(store.newSessionPlan().reason ?? "")
        }
    }

    private func clearFilters() {
        query = ""
        filterAttached = false
        filterRunning = false
        filterNeedsYou = false
        filterIdle = false
        filterUnread = false
    }
}

/// A column of the board: its title and count, and its cards scrolling
/// under them.
struct AgentHomeColumn<Cards: View>: View {
    let section: AgentHomeSection
    let count: Int
    /// The selected card, kept in view as the arrow keys move.
    let selection: AgentLane.ID?
    @ViewBuilder let cards: () -> Cards

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(section.title)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.headline)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    cards()
                    if count == 0 {
                        Text("None")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: selection) {
                if let selection { proxy.scrollTo(selection) }
            }
            }
        }
        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title), \(count) \(count == 1 ? "session" : "sessions")")
    }
}

/// One session on the board: its status, title and section, what it is
/// waiting on or doing, its pull requests and how long since it last did
/// anything.
struct AgentHomeCard: View {
    @ObservedObject var session: AgentLaneSession
    let area: String?
    let isSelected: Bool
    /// The board has the keyboard: the selection draws in the accent
    /// colour, else in grey, as a list's selection does.
    let isFocused: Bool
    var showsPullRequests = false
    var badges: LaneBadges? = nil

    static let pillLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AgentHomeStatusDot(session: session)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(session.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .layoutPriority(1)
                if session.needsAttention {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.tint)
                        .help("New since you last looked")
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                age
            }
            if area != nil || badges != nil {
                HStack(spacing: 6) {
                    if let area { Text(area).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 2)
                    if let badges { LaneBadgeStrip(badges: badges) }
                }
            }
            if let hint = session.standingHint, hint.isStale, let host = hint.host {
                Label {
                    if let seen = hint.seen {
                        Text("\(host) · last seen \(seen, format: .relative(presentation: .named))")
                    } else {
                        Text("\(host) · not seen yet")
                    }
                } icon: {
                    Image(systemName: "clock.badge.questionmark")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("\(host) has not reported lately, so this is how the session was when it last did")
            }
            Text(AgentHome.detail(for: session) ?? session.status.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            pills
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? (isFocused ? Color.accentColor : Color.secondary)
                              : Color(nsColor: .separatorColor),
                              lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(session.shortDirectory)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the session")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var pills: some View {
        let pullRequests = showsPullRequests ? session.displayedPullRequests : []
        if !pullRequests.isEmpty {
            let shown = Array(pullRequests.suffix(Self.pillLimit))
            AgentHomeFlow(spacing: 4) {
                ForEach(shown) { PullRequestBadge(pullRequest: $0).fixedSize() }
                if pullRequests.count > shown.count {
                    Text("+\(pullRequests.count - shown.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(pullRequests.count) pull requests in all")
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var age: some View {
        if let last = session.lastActivity {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.age(of: last, now: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(last.formatted(date: .abbreviated, time: .shortened))
            }
            .fixedSize()
        }
    }

    /// "now", "5m", "3h", "2d": the last activity as a short age.
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    private var accessibilityValue: String {
        var parts = [session.status.title]
        if let area { parts.append(area) }
        if let badges { parts.append(badges.summary) }
        if let detail = AgentHome.detail(for: session) { parts.append(detail) }
        parts += session.displayedPullRequests.map(\.accessibilityDescription)
        if let last = session.lastActivity {
            parts.append(last.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: ", ")
    }
}

/// Lays its views out left to right, wrapping onto new lines: a card's
/// pull request pills.
struct AgentHomeFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// The status colours the sidebar uses: green working, orange asking
/// permission, blue waiting for you, grey quiet, an outline when nothing
/// runs.
struct AgentHomeStatusDot: View {
    @ObservedObject var session: AgentLaneSession

    var body: some View {
        Group {
            switch session.status {
            case .running: Circle().fill(Color.green)
            case .permissionRequested: Circle().fill(Color.orange)
            case .waitingForInput: Circle().fill(Color.blue)
            case .done, .idle, .attached: Circle().fill(Color.secondary)
            case .notOpened, .detached, .unknown: Circle().strokeBorder(Color.secondary, lineWidth: 1)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}
