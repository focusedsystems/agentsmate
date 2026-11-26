import AppKit
import SwiftUI

/// Constants of the main window toolbar every app shares.
public enum AgentsToolbar {
    /// The agent symbol where the system has it (macOS 15.1 and later),
    /// sparkles before that.
    public static let agentSymbol = NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) != nil
        ? "apple.intelligence" : "sparkles"

    /// The Agents button's icon: Lucide's `bot`, bundled. One value, so a
    /// different robot (Phosphor `robot`, Tabler `robot-face`) is one change.
    public static let agentsIcon = LaneIcon.bundled("bot")

    /// The Agents button's title, and the label AppKit knows its item by.
    public static let agentsTitle = "Agents"

    /// The height of the circular sidebar toggle the button sits beside, and
    /// so of the button.
    public static let buttonHeight: CGFloat = 36

    /// The toolbar's leading and trailing controls each take up to this much,
    /// and the tab bar is centred, so it can use the window less twice this.
    public static let sideReserve: CGFloat = 620

    /// The search field is narrower in a narrow window, so it keeps its place.
    public static func searchWidth(forWindow width: CGFloat) -> CGFloat { width < 1200 ? 240 : 320 }

    /// The labels of the window-wide items, which AppKit keeps ahead of the
    /// app's own when the toolbar runs short.
    public static let windowItemLabels: Set<String> = ["Back", "Forward", "Agents", "Search"]
}

/// What the toolbar's Agents button shows and does: one control for Agents
/// mode, with All Agents as the view it opens on.
public struct AgentsToolbarAgent {
    public var isOn: Bool
    public var icon: LaneIcon
    public var help: String
    public var action: () -> Void
    /// Entering Agents mode (the button pressed while off) selects All Agents
    /// in this store first.
    public var store: AgentLaneStore?

    public init(isOn: Bool, store: AgentLaneStore? = nil, icon: LaneIcon = AgentsToolbar.agentsIcon,
                help: String? = nil, action: @escaping () -> Void) {
        self.isOn = isOn
        self.store = store
        self.icon = icon
        self.help = help ?? (isOn ? "Leave Agents (⇧⌘A)" : "Work with your agents (⇧⌘A)")
        self.action = action
    }

    /// Press the button: All Agents first when it is entering Agents mode.
    @MainActor
    func press() {
        if !isOn { store?.showHome() }
        action()
    }
}

/// What Back and Forward in the toolbar know and do.
public struct AgentsToolbarHistory {
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var goBack: () -> Void
    public var goForward: () -> Void
    /// The shortcuts the app's menu really gives Back and Forward, such as
    /// `⌘[`, for the tooltips. Nil shows none, so a tooltip never names a key
    /// the app does not use.
    public var backShortcut: String?
    public var forwardShortcut: String?

    public init(canGoBack: Bool, canGoForward: Bool, backShortcut: String? = nil, forwardShortcut: String? = nil,
                goBack: @escaping () -> Void, goForward: @escaping () -> Void) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.backShortcut = backShortcut
        self.forwardShortcut = forwardShortcut
        self.goBack = goBack
        self.goForward = goForward
    }
}

/// The toolbar's Agents control: a robot and "Agents", as tall as the circular
/// sidebar toggle it sits beside. Always on neutral glass, never a coloured
/// fill: the robot and label are in the accent colour while Agents mode is
/// off, as the way in, and in the label colour while it is on. It carries
/// ⇧⌘A, which toggles Agents mode from anywhere.
public struct AgentsToolbarButton: View {
    private let agent: AgentsToolbarAgent
    /// Off only offscreen, where the system's glass does not draw.
    private var drawsGlass = true

    public init(_ agent: AgentsToolbarAgent) { self.agent = agent }

    init(_ agent: AgentsToolbarAgent, drawsGlass: Bool) {
        self.agent = agent
        self.drawsGlass = drawsGlass
    }

    public var body: some View {
        let isOn = agent.isOn
        let button = Button { agent.press() } label: {
            HStack(spacing: 6) {
                LaneIconView(icon: agent.icon, tint: isOn ? Color.primary : Color.accentColor, size: 16)
                    .accessibilityHidden(true)
                Text(AgentsToolbar.agentsTitle)
            }
            .foregroundStyle(isOn ? Color.primary : Color.accentColor)
            .padding(.horizontal, 14)
            .frame(height: AgentsToolbar.buttonHeight)
        }
        styled(button, isOn: isOn)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help(agent.help)
            .accessibilityLabel(AgentsToolbar.agentsTitle)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private func styled(_ button: some View, isOn: Bool) -> some View {
        if !drawsGlass {
            button.buttonStyle(.plain)
                .background(Color.primary.opacity(0.08), in: Capsule())
        } else {
            button.buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .contentShape(Capsule())
        }
    }
}

/// Back and Forward, the same pair on every app.
public struct AgentsToolbarHistoryButtons: View {
    private let history: AgentsToolbarHistory

    public init(_ history: AgentsToolbarHistory) { self.history = history }

    public var body: some View {
        Button(action: history.goBack) {
            Label("Back", systemImage: "chevron.left")
        }
        .help(history.backShortcut.map { "Back (\($0))" } ?? "Back")
        .disabled(!history.canGoBack)
        Button(action: history.goForward) {
            Label("Forward", systemImage: "chevron.right")
        }
        .help(history.forwardShortcut.map { "Forward (\($0))" } ?? "Forward")
        .disabled(!history.canGoForward)
    }
}

/// The main window's toolbar: Agent at the far left, Back and Forward, the
/// tabs in the centre, then whatever the app puts at the right. The same in
/// every app, so only the tabs and the trailing controls differ.
public struct AgentsMainToolbar<ID: Hashable, Trailing: ToolbarContent>: ToolbarContent {
    private let agent: AgentsToolbarAgent?
    private let history: AgentsToolbarHistory
    private let tabs: [CollapsingTab<ID>]
    private let selection: Binding<ID>
    private let windowWidth: CGFloat
    private let onSelect: () -> Void
    private let agentInSidebar: Bool
    private let trailing: Trailing?

    /// `agentInSidebar` is true while the sidebar is expanded and carries the
    /// Agents button in its own titlebar space (``View/agentsSidebarToolbar(_:visible:)``),
    /// so the toolbar leaves it out; collapsed, it leads the toolbar.
    public init(agent: AgentsToolbarAgent?, history: AgentsToolbarHistory, tabs: [CollapsingTab<ID>],
                selection: Binding<ID>, windowWidth: CGFloat, agentInSidebar: Bool = false,
                onSelect: @escaping () -> Void = {}, @ToolbarContentBuilder trailing: () -> Trailing) {
        self.init(agent: agent, history: history, tabs: tabs, selection: selection, windowWidth: windowWidth,
                  agentInSidebar: agentInSidebar, onSelect: onSelect, content: trailing())
    }

    private init(agent: AgentsToolbarAgent?, history: AgentsToolbarHistory, tabs: [CollapsingTab<ID>],
                 selection: Binding<ID>, windowWidth: CGFloat, agentInSidebar: Bool, onSelect: @escaping () -> Void,
                 content: Trailing?) {
        self.agentInSidebar = agentInSidebar
        self.agent = agent
        self.history = history
        self.tabs = tabs
        self.selection = selection
        self.windowWidth = windowWidth
        self.onSelect = onSelect
        self.trailing = content
    }

    public var body: some ToolbarContent {
        // Agent is the app's core action, so it sits at the far left, ahead
        // of history, on every tab.
        if let agent, !agentInSidebar {
            ToolbarItem(placement: .navigation) {
                AgentsToolbarButton(agent)
            }
            // Its own glass button, not one more chip in a shared group.
            .sharedBackgroundVisibility(.hidden)
        }
        // Browser-style history, mirrored on ⌘[ / ⌘].
        ToolbarItemGroup(placement: .navigation) {
            AgentsToolbarHistoryButtons(history)
        }
        // A single tab needs no tab bar.
        // The bar draws its own glass and hugs its visible tabs; the item
        // reserves the room a hovered tab's name needs, so the system's glass
        // behind the item is hidden or it shows empty on both sides.
        if tabs.count > 1 {
            ToolbarItem(placement: .principal) {
                CollapsingTabBar(selection: selection, tabs: tabs,
                                 availableWidth: windowWidth - AgentsToolbar.sideReserve * 2,
                                 onSelect: onSelect)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // Push every trailing control to the window's right edge.
        ToolbarSpacer(.flexible, placement: .primaryAction)
        if let trailing { trailing }
    }
}

/// No controls after the tabs. A toolbar built this way never draws it.
public struct AgentsNoTrailing: ToolbarContent {
    public init() {}
    public var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { EmptyView() }
    }
}

extension AgentsMainToolbar where Trailing == AgentsNoTrailing {
    /// A toolbar with nothing after the tabs.
    public init(agent: AgentsToolbarAgent?, history: AgentsToolbarHistory, tabs: [CollapsingTab<ID>],
                selection: Binding<ID>, windowWidth: CGFloat, agentInSidebar: Bool = false,
                onSelect: @escaping () -> Void = {}) {
        self.init(agent: agent, history: history, tabs: tabs, selection: selection, windowWidth: windowWidth,
                  agentInSidebar: agentInSidebar, onSelect: onSelect, content: nil)
    }
}

/// The window chrome that goes with ``AgentsMainToolbar``: the window's width
/// for the tab bar, AppKit's ranking of the toolbar items, and the search
/// field as the toolbar's last item.
private struct AgentsMainWindowChrome<Search: View>: ViewModifier {
    @Binding var windowWidth: CGFloat
    let labels: Set<String>
    let search: ((CGFloat) -> Search)?

    func body(content: Content) -> some View {
        content
            // A preference read through a background GeometryReader stopped
            // updating once the window had been narrowed, so widening it
            // again left the toolbar compact. Observe the geometry directly.
            .modifier(WindowWidthReader(width: $windowWidth))
            .background(AgentsToolbarPriorityBridge(labels: labels))
            .modifier(AgentsToolbarSearchItem(width: AgentsToolbar.searchWidth(forWindow: windowWidth), search: search))
    }
}

/// The search field as a toolbar item, so the system draws it as the glass
/// capsule every native toolbar search has, the one Mail's toolbar shows. A
/// fixed space keeps the capsule apart from the items before it. The priority
/// bridge keeps the item out of the overflow menu.
private struct AgentsToolbarSearchItem<Search: View>: ViewModifier {
    let width: CGFloat
    let search: ((CGFloat) -> Search)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let search {
            content.toolbar {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { search(width) }
            }
        } else {
            content
        }
    }
}

private struct WindowWidthReader: ViewModifier {
    @Binding var width: CGFloat

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

extension View {
    /// The Agents button in the sidebar column's titlebar space, beside the
    /// sidebar toggle, while the sidebar is `visible`. Put it on the sidebar's
    /// content, and pass the same flag as `agentInSidebar` to
    /// ``AgentsMainToolbar`` so the button is in one place at a time. The item
    /// is declared either way (removing it left an empty glass pill) and only
    /// its content comes and goes.
    public func agentsSidebarToolbar(_ agent: AgentsToolbarAgent, visible: Bool) -> some View {
        modifier(AgentsSidebarToolbar(agent: agent, visible: visible))
    }

    /// Gives the window the toolbar's chrome: the width the tab bar needs,
    /// the ranking of its items, and, when `search` is given, the search field
    /// pinned to the title bar at the width it is handed. Put the
    /// ``AgentsMainToolbar`` in `.toolbar` on the same view.
    public func agentsMainWindowChrome<Search: View>(
        windowWidth: Binding<CGFloat>,
        extraItemLabels: Set<String> = [],
        @ViewBuilder search: @escaping (CGFloat) -> Search
    ) -> some View {
        modifier(AgentsMainWindowChrome(windowWidth: windowWidth,
                                        labels: AgentsToolbar.windowItemLabels.union(extraItemLabels),
                                        search: search))
    }

    /// As above, for an app with no search field.
    public func agentsMainWindowChrome(windowWidth: Binding<CGFloat>, extraItemLabels: Set<String> = []) -> some View {
        modifier(AgentsMainWindowChrome<EmptyView>(windowWidth: windowWidth,
                                                  labels: AgentsToolbar.windowItemLabels.union(extraItemLabels),
                                                  search: nil))
    }
}

/// Ranks secondary toolbar actions after the module navigation. The search
/// field's item ranks highest of all, so it never enters overflow.
struct AgentsToolbarPriorityBridge: NSViewRepresentable {
    let labels: Set<String>

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.labels = labels
        // SwiftUI rebuilds the toolbar's items when the module changes.
        view.scheduleApply()
    }

    final class BridgeView: NSView {
        var labels: Set<String> = []
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        private var applyPending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSToolbar.willAddItemNotification,
                                                object: nil, queue: .main) { [weak self] note in
                let toolbar = note.object as? NSToolbar
                MainActor.assumeIsolated {
                    guard let self, let toolbar, toolbar === self.window?.toolbar else { return }
                    self.scheduleApply()
                }
            })
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleApply() }
            })
            scheduleApply()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Coalesced and deferred: items are announced before they are added.
        func scheduleApply() {
            guard !applyPending else { return }
            applyPending = true
            DispatchQueue.main.async { [weak self] in
                self?.applyPending = false
                self?.apply()
            }
        }

        private func apply() {
            guard let toolbar = window?.toolbar else { return }
            for item in toolbar.items {
                if item.itemIdentifier == .flexibleSpace || item.itemIdentifier == .space { continue }
                let priority: NSToolbarItem.VisibilityPriority
                if item.itemIdentifier == toolbar.centeredItemIdentifier || Self.holdsSearchField(item) {
                    priority = .high
                } else if labels.contains(item.label) {
                    priority = .high
                    if item.label == AgentsToolbar.agentsTitle { useAgentsIcon(item) }
                } else {
                    priority = .low
                }
                if item.visibilityPriority != priority { item.visibilityPriority = priority }
            }
        }

        private static func holdsSearchField(_ item: NSToolbarItem) -> Bool {
            func find(_ view: NSView) -> Bool {
                view is NSSearchField || view.subviews.contains(where: find)
            }
            return item.view.map(find) ?? false
        }

        /// The overflow menu drew Agents with a generic glyph; it is the
        /// Agents icon everywhere.
        private func useAgentsIcon(_ item: NSToolbarItem) {
            let image: NSImage?
            switch AgentsToolbar.agentsIcon {
            case .symbol(let name): image = LaneIconLibrary.symbolImage(name)
            case .bundled(let name): image = LaneIconLibrary.bundledImage(name)
            }
            guard let image else { return }
            if item.image == nil { item.image = image }
            if let menuItem = item.menuFormRepresentation, menuItem.image !== image {
                menuItem.image = image
                item.menuFormRepresentation = menuItem
            }
        }
    }
}

/// The toolbar's controls in a row, drawn without a window, so a snapshot can
/// show what a window at `width` would. The system draws glass only on screen,
/// so each control falls back to a flat fill here.
public struct AgentsToolbarStrip<ID: Hashable, Trailing: View>: View {
    private let agent: AgentsToolbarAgent?
    private let tabs: [CollapsingTab<ID>]
    private let selection: ID
    private let width: CGFloat
    private let search: (prompt: String, hint: String)?
    private let trailing: Trailing?

    public init(agent: AgentsToolbarAgent?, tabs: [CollapsingTab<ID>], selection: ID, width: CGFloat,
                search: (prompt: String, hint: String)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.agent = agent
        self.tabs = tabs
        self.selection = selection
        self.width = width
        self.search = search
        self.trailing = trailing()
    }

    public var body: some View {
        ZStack {
            CollapsingTabBar(selection: .constant(selection), tabs: tabs,
                             availableWidth: width - AgentsToolbar.sideReserve * 2, hovered: nil)
            HStack(spacing: 8) {
                if let agent { AgentsToolbarButton(agent, drawsGlass: false) }
                ForEach(["chevron.left", "chevron.right"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                Spacer(minLength: 0)
                trailing
                if let search {
                    AgentsToolbarSearchField(offscreen: .constant(""), prompt: search.prompt, hint: search.hint,
                                             width: AgentsToolbar.searchWidth(forWindow: width))
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The sidebar column's Agents item. The availability check is made on the
/// view, not inside the toolbar builder, so no conditional toolbar content
/// is built: an app target linking an older SwiftUI cannot resolve one.
private struct AgentsSidebarToolbar: ViewModifier {
    let agent: AgentsToolbarAgent
    let visible: Bool

    func body(content: Content) -> some View {
        content.toolbar { AgentsSidebarItem(agent: agent, visible: visible) }
    }
}

private struct AgentsSidebarItem: ToolbarContent {
    let agent: AgentsToolbarAgent
    let visible: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            if visible { AgentsToolbarButton(agent) }
        }
        .sharedBackgroundVisibility(.hidden)
    }
}
