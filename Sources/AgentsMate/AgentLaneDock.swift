import SwiftUI
import AppKit

/// The lanes as a panel under an app's own content, the way Xcode and VS
/// Code show a terminal: put it at the bottom of a `VStack` after the
/// content, and hide the content while ``AgentLaneStore/dockMaximized``.
///
/// Drag the divider to resize it (the height is saved), drag it to the
/// bottom or double-click it to close, drag it near the top to fill the
/// window. The lane list sits at the left of the panel; the terminals fill
/// the rest.
public struct AgentLaneDock<Accessory: View, Empty: View>: View {
    @ObservedObject var store: AgentLaneStore
    let labels: AgentsModeLabels
    let accessory: Accessory
    let empty: Empty

    @AppStorage private var height: Double
    @AppStorage private var listWidth: Double
    @State private var dragStart: Double?
    @State private var liveHeight: Double?
    @State private var listDragStart: Double?

    static var minimumHeight: Double { 120 }
    static var closeBelow: Double { 80 }

    public init(store: AgentLaneStore, labels: AgentsModeLabels = .init(),
                @ViewBuilder accessory: () -> Accessory, @ViewBuilder empty: () -> Empty) {
        self.store = store
        self.labels = labels
        self.accessory = accessory()
        self.empty = empty()
        _height = AppStorage(wrappedValue: 280, store.keys.dockHeight)
        _listWidth = AppStorage(wrappedValue: 230, store.keys.dockListWidth)
    }

    public var body: some View {
        if store.dockVisible {
            VStack(spacing: 0) {
                if !store.dockMaximized { divider }
                HStack(spacing: 0) {
                    AgentLaneSidebar(store: store, labels: labels, inDock: true) { accessory }
                        .frame(width: CGFloat(listWidth))
                    listDivider
                    AgentLaneDetail(store: store, labels: labels) { empty }
                }
                .frame(height: store.dockMaximized ? nil : CGFloat(liveHeight ?? height))
                .frame(maxHeight: store.dockMaximized ? .infinity : nil)
            }
            .transition(.move(edge: .bottom))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? height
                        dragStart = start
                        liveHeight = min(max(start - value.translation.height, 24), 2000)
                    }
                    .onEnded { value in
                        let proposed = (dragStart ?? height) - value.translation.height
                        let available = NSApp.keyWindow?.contentLayoutRect.height ?? 900
                        if proposed < Self.closeBelow {
                            store.hideDock()
                        } else if proposed > available * 0.85 {
                            store.dockMaximized = true
                        } else {
                            height = min(max(proposed, Self.minimumHeight), 2000)
                        }
                        liveHeight = nil
                        dragStart = nil
                    }
            )
            .onTapGesture(count: 2) { store.hideDock() }
            .help("Drag to resize; drag to the bottom or double-click to close (⌃`)")
            .accessibilityElement()
            .accessibilityLabel("\(labels.listTitle) dock divider")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Close") { store.hideDock() }
            .accessibilityAction(named: "Fill Window") { store.dockMaximized = true }
    }

    private var listDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = listDragStart ?? listWidth
                        listDragStart = start
                        listWidth = min(max(start + value.translation.width, 160), 480)
                    }
                    .onEnded { _ in listDragStart = nil }
            )
            .accessibilityHidden(true)
    }
}

public extension AgentLaneDock where Accessory == EmptyView {
    init(store: AgentLaneStore, labels: AgentsModeLabels = .init(), @ViewBuilder empty: () -> Empty) {
        self.init(store: store, labels: labels, accessory: { EmptyView() }, empty: empty)
    }
}

/// View-menu items for an app that shows the lanes as a dock: Show/Hide
/// (titled by what it will do) and Fill Window.
public struct AgentLaneDockMenuItems: View {
    @ObservedObject var store: AgentLaneStore
    let noun: String

    public init(store: AgentLaneStore, noun: String = "Agent") {
        self.store = store
        self.noun = noun
    }

    public var body: some View {
        Button(store.dockVisible ? "Hide \(noun)" : "Show \(noun)") { store.toggleDock() }
        Button(store.dockMaximized ? "Restore \(noun) Panel" : "\(noun) Fills Window") {
            if !store.dockVisible { store.showDock() }
            store.dockMaximized.toggle()
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
    }
}
