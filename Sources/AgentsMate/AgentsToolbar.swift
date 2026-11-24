import AppKit
import SwiftUI

/// Constants of the main window toolbar every app shares.
public enum AgentsToolbar {
    /// The agent symbol where the system has it (macOS 15.1 and later),
    /// sparkles before that.
    public static let agentSymbol = NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) != nil
        ? "apple.intelligence" : "sparkles"

    /// The toolbar's leading and trailing controls each take up to this much,
    /// and the tab bar is centred, so it can use the window less twice this.
    public static let sideReserve: CGFloat = 620

    /// The search field is narrower in a narrow window, so it keeps its place.
    public static func searchWidth(forWindow width: CGFloat) -> CGFloat { width < 1200 ? 240 : 320 }

    /// The labels of the window-wide items, which AppKit keeps ahead of the
    /// app's own when the toolbar runs short.
    public static let windowItemLabels: Set<String> = ["Back", "Forward", "Agent", "Search"]
}

/// What the toolbar's Agent button shows and does.
public struct AgentsToolbarAgent {
    public var isOn: Bool
    public var symbol: String
    public var help: String
    public var action: () -> Void

    public init(isOn: Bool, symbol: String = AgentsToolbar.agentSymbol, help: String? = nil,
                action: @escaping () -> Void) {
        self.isOn = isOn
        self.symbol = symbol
        self.help = help ?? (isOn ? "Hide the agent terminal (⌘J or ⌃`)" : "Work with the agent in the terminal (⌘J or ⌃`)")
        self.action = action
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

/// The toolbar's Agent control, the first item at the far left: blue invites
/// you into the agent; once it is open the button goes plain like the
/// toolbar's other controls, with the same icon. ⌃` toggles it from anywhere.
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
        let button = Button(action: agent.action) {
            Label("Agent", systemImage: agent.symbol)
                .labelStyle(.titleAndIcon)
        }
        styled(button)
            .keyboardShortcut("`", modifiers: .control)
            .help(agent.help)
            .accessibilityLabel("Agent")
            .accessibilityValue(agent.isOn ? "On" : "Off")
            .accessibilityAddTraits(agent.isOn ? .isSelected : [])
    }

    @ViewBuilder
    private func styled(_ button: some View) -> some View {
        let isOn = agent.isOn
        if !drawsGlass {
            button.buttonStyle(.plain)
                .foregroundStyle(isOn ? Color.primary : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isOn ? Color.primary.opacity(0.12) : Color.accentColor, in: Capsule())
        } else if #available(macOS 26.0, *) {
            // Both states are drawn here at the same size, so the button does
            // not shift when clicked. The window toolbar greys out
            // .glassProminent's tint, so the blue is drawn as tinted glass.
            button.buttonStyle(.plain)
                .foregroundStyle(isOn ? Color.primary : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassEffect(isOn ? .regular.interactive() : .regular.tint(.accentColor).interactive(), in: .capsule)
                .contentShape(Capsule())
        } else {
            if isOn { button.buttonStyle(.bordered) } else { button.buttonStyle(.borderedProminent).tint(.accentColor) }
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
    private let trailing: Trailing?

    public init(agent: AgentsToolbarAgent?, history: AgentsToolbarHistory, tabs: [CollapsingTab<ID>],
                selection: Binding<ID>, windowWidth: CGFloat, onSelect: @escaping () -> Void = {},
                @ToolbarContentBuilder trailing: () -> Trailing) {
        self.init(agent: agent, history: history, tabs: tabs, selection: selection, windowWidth: windowWidth,
                  onSelect: onSelect, content: trailing())
    }

    private init(agent: AgentsToolbarAgent?, history: AgentsToolbarHistory, tabs: [CollapsingTab<ID>],
                 selection: Binding<ID>, windowWidth: CGFloat, onSelect: @escaping () -> Void, content: Trailing?) {
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
        if let agent {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    AgentsToolbarButton(agent)
                }
                // Its own glass button, not one more chip in a shared group.
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    AgentsToolbarButton(agent)
                }
            }
        }
        // Browser-style history, mirrored on ⌘[ / ⌘].
        ToolbarItemGroup(placement: .navigation) {
            AgentsToolbarHistoryButtons(history)
        }
        // A single tab needs no tab bar.
        if tabs.count > 1 {
            ToolbarItem(placement: .principal) {
                CollapsingTabBar(selection: selection, tabs: tabs,
                                 availableWidth: windowWidth - AgentsToolbar.sideReserve * 2,
                                 onSelect: onSelect)
            }
        }
        // Push every trailing control to the window's right edge.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
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
                selection: Binding<ID>, windowWidth: CGFloat, onSelect: @escaping () -> Void = {}) {
        self.init(agent: agent, history: history, tabs: tabs, selection: selection, windowWidth: windowWidth,
                  onSelect: onSelect, content: nil)
    }
}

/// The window chrome that goes with ``AgentsMainToolbar``: the window's width
/// for the tab bar, AppKit's ranking of the toolbar items, and the search
/// field pinned to the title bar.
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
            .background {
                if let search {
                    AgentsPinnedSearchTitlebar(width: AgentsToolbar.searchWidth(forWindow: windowWidth)) {
                        search(AgentsToolbar.searchWidth(forWindow: windowWidth))
                    }
                }
            }
    }
}

private struct WindowWidthReader: ViewModifier {
    @Binding var width: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        } else {
            content.background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, new in width = new }
            })
        }
    }
}

extension View {
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

/// Ranks secondary toolbar actions after the module navigation. Search is
/// reserved independently by ``AgentsPinnedSearchTitlebar`` and never enters
/// overflow.
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
                if item.itemIdentifier == toolbar.centeredItemIdentifier {
                    priority = .high
                } else if labels.contains(item.label) {
                    priority = .high
                    if item.label == "Agent" { useAgentSymbol(item) }
                } else {
                    priority = .low
                }
                if item.visibilityPriority != priority { item.visibilityPriority = priority }
            }
        }

        /// The overflow menu drew Agent with a generic glyph; it is the
        /// agent symbol everywhere.
        private func useAgentSymbol(_ item: NSToolbarItem) {
            let image = NSImage(systemSymbolName: AgentsToolbar.agentSymbol, accessibilityDescription: "Agent")
            if item.image == nil { item.image = image }
            if let menuItem = item.menuFormRepresentation, menuItem.image?.name() != image?.name() {
                menuItem.image = image
                item.menuFormRepresentation = menuItem
            }
        }
    }
}

/// Search belongs to the window title bar, outside NSToolbar's overflow
/// system. A trailing accessory reserves its width before AppKit lays out
/// toolbar items.
struct AgentsPinnedSearchTitlebar: NSViewRepresentable {
    let width: CGFloat
    let content: AnyView

    init<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = AnyView(content())
    }

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.configure(content: content, width: width)
    }

    static func dismantleNSView(_ view: BridgeView, coordinator: ()) { view.detach() }

    final class BridgeView: NSView {
        private var accessory: NSTitlebarAccessoryViewController?
        private var hosting: NSHostingView<AnyView>?
        private weak var attachedWindow: NSWindow?
        private var content = AnyView(EmptyView())
        private var width: CGFloat = 320

        func configure(content: AnyView, width: CGFloat) {
            self.content = content
            self.width = width
            install()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if attachedWindow !== window { detach() }
            install()
        }

        private func install() {
            guard let window else { return }
            let root = AnyView(content
                .padding(.horizontal, 8)
                .frame(width: width + 16, height: 44))
            if let hosting {
                hosting.rootView = root
                hosting.setFrameSize(NSSize(width: width + 16, height: 44))
                return
            }
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(x: 0, y: 0, width: width + 16, height: 44)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .right
            accessory.view = hosting
            // A hidden title tells AppKit to reserve accessory width for the toolbar.
            window.titleVisibility = .hidden
            window.addTitlebarAccessoryViewController(accessory)
            self.hosting = hosting
            self.accessory = accessory
            attachedWindow = window
        }

        func detach() {
            if let window = attachedWindow, let accessory,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            accessory = nil
            hosting = nil
            attachedWindow = nil
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
