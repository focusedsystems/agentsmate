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

    @AppStorage private var filterAttached: Bool
    @AppStorage private var filterRunning: Bool
    @AppStorage private var filterNeedsYou: Bool
    @State private var searchText = ""

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

    public var body: some View {
        List(selection: selectionBinding) {
            Section {
                ForEach(visibleLanes) { lane in
                    if let session = store.session(for: lane) {
                        LaneRow(session: session,
                                index: store.lanes.firstIndex(of: lane) ?? 0,
                                isSplit: lane.id == store.splitID)
                            .tag(lane.id)
                    }
                }
            } header: {
                HStack {
                    Text(labels.listTitle)
                    Spacer()
                    accessory
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search \(labels.laneNoun)s")
        .safeAreaInset(edge: .top, spacing: 0) {
            filterBar
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
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

    private var selectionBinding: Binding<AgentLane.ID?> {
        Binding(get: { store.selectedID },
                set: { id in
                    // Moving through the list attaches each lane but leaves
                    // the keyboard in the list; Return or a double-click
                    // hands it to the terminal.
                    if let id { store.open(id, focus: false) }
                })
    }

    @ViewBuilder
    private func rowMenu(_ session: AgentLaneSession) -> some View {
        let lane = session.lane
        Button("Open \(session.title)") { store.open(lane.id) }
        Button("Reattach") { store.reattach(lane.id) }
            .disabled(!session.isStarted)
        Button("Detach") { store.detach(lane.id) }
            .disabled(!session.isAttached)
        if session.backend.canStop {
            Button("Stop Lane") { store.stop(lane.id) }
                .help("End the session; its conversation resumes when the lane is opened again")
        }
        if lane.isClosable {
            Button("Close") { store.close(lane.id) }
        }
        Divider()
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

struct LaneRow: View {
    @ObservedObject var session: AgentLaneSession
    let index: Int
    let isSplit: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.lane.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(session.lane.tintHex.flatMap(Color.init(laneHex:)) ?? Color.accentColor)
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
        if session.isOrphan, !session.isAttached { return "Running, nothing attached" }
        if session.lane.isClosable, session.status == .attached || session.status == .detached {
            return session.shortDirectory
        }
        return isSplit ? "\(session.status.title) · split" : session.status.title
    }

    private var helpText: String {
        var lines = ["\(session.title) — \(session.status.title)", session.shortDirectory]
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

