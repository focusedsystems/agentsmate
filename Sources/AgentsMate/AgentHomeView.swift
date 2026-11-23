import SwiftUI
import AppKit

/// Home: every active session in the app's lanes at a glance, grouped
/// into Needs You, Working and Idle & Done. ``AgentLaneDetail`` shows it in
/// place of the terminal while ``AgentLaneStore/isHomeShown``; an app with
/// its own layout can show it anywhere.
///
/// Click a row, or move to it with the arrow keys and press Return, to open
/// its lane exactly as the sidebar does. Typing filters the list; the
/// sidebar's status filters apply here too. It fills in as hosts answer and
/// never waits on them.
public struct AgentHomeView: View {
    @ObservedObject var store: AgentLaneStore
    let labels: AgentsModeLabels
    let rowActions: [LaneAction]

    @StateObject private var menus = LaneMenuPresentation()
    @State private var selection: AgentLane.ID?
    @State private var query = ""
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    @AppStorage private var filterAttached: Bool
    @AppStorage private var filterRunning: Bool
    @AppStorage private var filterNeedsYou: Bool
    @AppStorage private var filterIdle: Bool
    @AppStorage private var filterUnread: Bool

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
    }

    public var body: some View {
        // Read once per update: the grouping walks every row.
        let groups = displayedGroups
        let totals = AgentHome.totals(allGroups)
        VStack(spacing: 0) {
            header(totals)
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                list(groups)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .modifier(LaneMenuSheets(store: store, presentation: menus))
        .onAppear { DispatchQueue.main.async { listFocused = true } }
    }

    // MARK: Rows

    private var sessionsByID: [AgentLane.ID: AgentLaneSession] { store.sessions }

    /// Every section with every row, before search and filters: the totals.
    private var allGroups: [(section: AgentHomeSection, items: [AgentHomeItem])] {
        AgentHome.grouped(store.homeSessions.map(AgentLaneStore.homeItem))
    }

    /// The sections with only the rows the search and the sidebar's status
    /// filters let through.
    private var displayedGroups: [(section: AgentHomeSection, items: [AgentHomeItem])] {
        let filters = activeFilters
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
        return AgentHome.grouped(sessions.map(AgentLaneStore.homeItem))
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

    private func list(_ groups: [(section: AgentHomeSection, items: [AgentHomeItem])]) -> some View {
        List(selection: selectionBinding) {
            ForEach(groups, id: \.section) { group in
                Section {
                    ForEach(group.items) { item in
                        if let session = sessionsByID[item.id] {
                            AgentHomeRow(session: session, area: store.homeArea(of: session.lane))
                                .tag(item.id)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(group.section.title)
                        Text("\(group.items.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.headline)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .focused($listFocused)
        .contextMenu(forSelectionType: AgentLane.ID.self) { ids in
            if let id = ids.first, let session = store.sessions[id] {
                LaneContextMenu(store: store, session: session, presentation: menus, rowActions: rowActions)
            }
        } primaryAction: { ids in
            if let id = ids.first { store.open(id) }
        }
        // Typing filters the list, as in Finder's and Mail's type-to-search
        // fields; Delete takes a character back and Escape clears it.
        .background(HomeTypeToSearch(handle: typeToSearch))
    }

    private func typeToSearch(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.keyCode {
        case 51, 117:
            guard !query.isEmpty else { return false }
            query.removeLast()
            return true
        case 53:
            guard !query.isEmpty else { return false }
            query = ""
            return true
        default:
            break
        }
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ Self.typeable.contains($0) }),
              !(chars == " " && query.isEmpty) else { return false }
        query += chars
        return true
    }

    private static let typeable = CharacterSet.alphanumerics.union(.punctuationCharacters)
        .union(.symbols).union(.init(charactersIn: " "))

    /// A click opens the row's lane, as in the sidebar; the arrow keys only
    /// move, and Return (the list's primary action) opens.
    private var selectionBinding: Binding<AgentLane.ID?> {
        Binding(get: { selection },
                set: { id in
                    selection = id
                    guard let id else { return }
                    let type = NSApp.currentEvent?.type
                    if type == .leftMouseDown || type == .leftMouseUp { store.open(id) }
                })
    }

    // MARK: Header

    private func header(_ totals: AgentHome.Totals) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Label("Home", systemImage: "house")
                    .font(.title2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .accessibilityAddTraits(.isHeader)
                total(totals.needsYou, "need you", symbol: "hand.raised.fill", color: .orange)
                total(totals.working, "working", symbol: "bolt.fill", color: .green)
                total(totals.recent, "idle or done", symbol: "moon.fill", color: .secondary)
                Spacer(minLength: 8)
                searchField
            }
            let loading = store.homeLoading
            if loading.isLoading { loadingRow(loading) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func total(_ count: Int, _ noun: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(count > 0 ? color : .secondary)
            Text("\(count)").monospacedDigit().fontWeight(.medium)
            Text(noun).foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(noun)")
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = ""; listFocused = true }
                .onSubmit { listFocused = true }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 6)
        .frame(width: 200, height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .help("Filter by name, folder, section, summary or your recent prompts; or just start typing in the list")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter sessions")
    }

    /// Loading sessions…, with a bar that fills as each host answers, and
    /// each host's state beside it.
    private func loadingRow(_ loading: AgentHomeLoading) -> some View {
        HStack(spacing: 10) {
            if loading.hosts.isEmpty {
                ProgressView().controlSize(.small)
                Text("Loading sessions…").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Loading sessions…").font(.callout).foregroundStyle(.secondary)
                ProgressView(value: Double(loading.hostsAnswered), total: Double(loading.hosts.count))
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Hosts answered")
                    .accessibilityValue("\(loading.hostsAnswered) of \(loading.hosts.count)")
                ForEach(loading.hosts) { host in
                    HStack(spacing: 3) {
                        switch host.state {
                        case .asking: ProgressView().controlSize(.mini)
                        case .answered: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .unreachable: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Text(host.name)
                    }
                    .font(.caption)
                    .help(host.state == .asking ? "Asking \(host.name) what it has running"
                          : host.state == .answered ? "\(host.name) answered"
                          : "\(host.name) did not answer; its sessions are unknown")
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(host.state == .asking ? "asking" : host.state == .answered ? "answered" : "no answer")
                }
                if loading.findingSessions {
                    Text("Looking for detached sessions…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "house").font(.system(size: 32)).foregroundStyle(.secondary)
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
                ForEach(backends, id: \.id) { backend in
                    Button("\(backend.displayName)…") {
                        Task { await store.newLane(in: LaneGroup(section: nil, lanes: []), backendID: backend.id) }
                    }
                }
            }
            .fixedSize()
            .controlSize(.large)
        } else {
            Button("New Session") {
                if let onNewLane = store.onNewLane {
                    onNewLane()
                } else {
                    Task { await store.newLane(in: LaneGroup(section: nil, lanes: []), backendID: store.newLaneBackendID) }
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
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

/// One session on Home: its status, title and section, what it is waiting
/// on or doing, its pull requests and how long since it last did anything.
struct AgentHomeRow: View {
    @ObservedObject var session: AgentLaneSession
    let area: String?

    static let pillLimit = 4

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentHomeStatusDot(session: session)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let area {
                        Text(area).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if session.needsAttention {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.tint)
                            .help("New since you last looked")
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 8)
                    pills
                    age
                }
                Text(AgentHome.detail(for: session) ?? session.status.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(session.shortDirectory)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the session")
    }

    @ViewBuilder
    private var pills: some View {
        let pullRequests = session.displayedPullRequests
        if !pullRequests.isEmpty {
            let shown = Array(pullRequests.suffix(Self.pillLimit))
            HStack(spacing: 4) {
                ForEach(shown) { PullRequestBadge(pullRequest: $0).fixedSize() }
                if pullRequests.count > shown.count {
                    Text("+\(pullRequests.count - shown.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(pullRequests.count) pull requests in all")
                }
            }
        }
    }

    @ViewBuilder
    private var age: some View {
        if let last = session.lastActivity {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.age(of: last, now: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
                    .help(last.formatted(date: .abbreviated, time: .shortened))
            }
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
        if let detail = AgentHome.detail(for: session) { parts.append(detail) }
        parts += session.displayedPullRequests.map(\.accessibilityDescription)
        if let last = session.lastActivity {
            parts.append(last.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: ", ")
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
            case .notOpened, .detached: Circle().strokeBorder(Color.secondary, lineWidth: 1)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

/// Hands key presses to Home's type-to-search while the list behind which
/// it sits has the keyboard, ahead of the list's own type-select.
struct HomeTypeToSearch: NSViewRepresentable {
    let handle: @MainActor (NSEvent) -> Bool

    func makeNSView(context: Context) -> HomeTypeToSearchView {
        let view = HomeTypeToSearchView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: HomeTypeToSearchView, context: Context) { view.handle = handle }
}

final class HomeTypeToSearchView: NSView {
    var handle: (@MainActor (NSEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.take(event) ?? false }
            return handled ? nil : event
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func take(_ event: NSEvent) -> Bool {
        guard event.window === window, listHasKeyboard, let handle else { return false }
        return handle(event)
    }

    /// Whether the window's focused view is the list this view sits behind.
    private var listHasKeyboard: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor,
              let focused = window.firstResponder as? NSTableView else { return false }
        let scroll = focused.enclosingScrollView ?? focused
        let list = scroll.convert(scroll.bounds, to: nil)
        let mine = convert(bounds, to: nil)
        return mine.insetBy(dx: -2, dy: -2).contains(list) || list.insetBy(dx: -2, dy: -2).contains(mine)
    }
}
