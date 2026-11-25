import AppKit
import SwiftUI

/// The height of the row at the top of the Agents sidebar and of the All
/// Agents header beside it, so the two line up.
public enum AgentsModeMetrics {
    public static let headerRowHeight: CGFloat = 38
}

/// One tab of a ``CollapsingTabBar``.
public struct CollapsingTab<ID: Hashable>: Identifiable {
    public var id: ID
    public var title: String
    public var systemImage: String
    /// Shown in the tooltip, such as `⌘2`.
    public var shortcut: String?

    public init(id: ID, title: String, systemImage: String, shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
    }
}

/// How wide a ``CollapsingTabBar`` is, and whether its other tabs show icons
/// only. Worked out from the titles, so the toolbar never has to negotiate.
public enum CollapsingTabLayout {
    static let iconWidth: CGFloat = 16
    static let labelGap: CGFloat = 5
    static let expandedPadding: CGFloat = 14
    static let collapsedPadding: CGFloat = 10
    static let barPadding: CGFloat = 3
    static let separatorWidth: CGFloat = 1

    static func labelWidth(_ title: String, selected: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    static func tabWidth(_ title: String, expanded: Bool, selected: Bool) -> CGFloat {
        guard expanded else { return iconWidth + collapsedPadding * 2 }
        return iconWidth + labelGap + labelWidth(title, selected: selected) + expandedPadding * 2
    }

    /// The bar with every tab named.
    public static func fullWidth(titles: [String], selected: String?) -> CGFloat {
        titles.reduce(barPadding * 2 + separatorWidth * CGFloat(max(0, titles.count - 1))) {
            $0 + tabWidth($1, expanded: true, selected: $1 == selected)
        }
    }

    /// The bar with only the open tab named.
    public static func collapsedWidth(titles: [String], selected: String?) -> CGFloat {
        titles.reduce(barPadding * 2 + separatorWidth * CGFloat(max(0, titles.count - 1))) {
            $0 + tabWidth($1, expanded: $1 == selected, selected: $1 == selected)
        }
    }

    /// The room a hovered tab needs on top of the collapsed bar: the widest
    /// other tab's name. The bar reserves it, so the toolbar never reflows
    /// under the pointer.
    public static func hoverAllowance(titles: [String], selected: String?) -> CGFloat {
        titles.filter { $0 != selected }.map {
            tabWidth($0, expanded: true, selected: false) - tabWidth($0, expanded: false, selected: false)
        }.max() ?? 0
    }

    /// Whether the other tabs collapse to icons in `availableWidth`.
    public static func collapses(titles: [String], selected: String?, availableWidth: CGFloat) -> Bool {
        fullWidth(titles: titles, selected: selected) > availableWidth
    }
}

/// The main tabs in the toolbar's centre. With room every tab is named; when
/// there is not, the tabs not open show their icon and name themselves on
/// hover or keyboard focus. The tabs stay on screen at every width and never
/// fold into a menu.
public struct CollapsingTabBar<ID: Hashable>: View {
    @Binding private var selection: ID
    private let tabs: [CollapsingTab<ID>]
    private let availableWidth: CGFloat
    private let onSelect: () -> Void
    /// Off only offscreen, where the system's glass does not draw.
    private var drawsGlass = true

    @State private var hovered: ID?
    @State private var clearHover: Task<Void, Never>?
    @FocusState private var focused: ID?
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `availableWidth` is what the toolbar can give the bar: the window's
    /// width less the controls on either side.
    public init(selection: Binding<ID>, tabs: [CollapsingTab<ID>], availableWidth: CGFloat,
                onSelect: @escaping () -> Void = {}) {
        _selection = selection
        self.tabs = tabs
        self.availableWidth = availableWidth
        self.onSelect = onSelect
    }

    /// A bar drawn with one tab already under the pointer, for offscreen checks.
    init(selection: Binding<ID>, tabs: [CollapsingTab<ID>], availableWidth: CGFloat, hovered: ID?) {
        self.init(selection: selection, tabs: tabs, availableWidth: availableWidth)
        _hovered = State(initialValue: hovered)
        drawsGlass = false
    }

    private var titles: [String] { tabs.map(\.title) }
    private var selectedTitle: String? { tabs.first { $0.id == selection }?.title }
    private var collapses: Bool {
        CollapsingTabLayout.collapses(titles: titles, selected: selectedTitle, availableWidth: availableWidth)
    }
    private var animation: Animation? { reduceMotion ? nil : .smooth(duration: 0.18) }

    private func isNamed(_ tab: CollapsingTab<ID>) -> Bool {
        !collapses || tab.id == selection || tab.id == hovered || tab.id == focused
    }

    public var body: some View {
        let collapses = collapses
        let reserved = collapses
            ? CollapsingTabLayout.collapsedWidth(titles: titles, selected: selectedTitle)
                + CollapsingTabLayout.hoverAllowance(titles: titles, selected: selectedTitle)
            : CollapsingTabLayout.fullWidth(titles: titles, selected: selectedTitle)
        bar
            .frame(width: reserved)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
    }

    private var bar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(tabs[index - 1].id != selection && tab.id != selection ? 0.25 : 0))
                        .frame(width: CollapsingTabLayout.separatorWidth, height: 16)
                }
                button(tab)
            }
        }
        .padding(CollapsingTabLayout.barPadding)
        .fixedSize()
        .modifier(CollapsingTabBarGlass(drawsGlass: drawsGlass))
        .animation(animation, value: hovered)
        .animation(animation, value: focused)
        .animation(animation, value: selection)
        .animation(animation, value: collapses)
    }

    private func button(_ tab: CollapsingTab<ID>) -> some View {
        let isSelected = tab.id == selection
        let named = isNamed(tab)
        return Button {
            onSelect()
            selection = tab.id
        } label: {
            HStack(spacing: named ? CollapsingTabLayout.labelGap : 0) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: named ? 11 : 13))
                    .frame(width: CollapsingTabLayout.iconWidth)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: named ? CollapsingTabLayout.labelWidth(tab.title, selected: isSelected) : 0,
                           alignment: .leading)
                    .clipped()
                    .opacity(named ? 1 : 0)
            }
            .padding(.horizontal, named ? CollapsingTabLayout.expandedPadding : CollapsingTabLayout.collapsedPadding)
            .padding(.vertical, 6)
            .contentShape(Capsule())
            .foregroundStyle(isSelected || tab.id == hovered ? Color.primary : Color.secondary)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.primary.opacity(0.12))
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($focused, equals: tab.id)
        .onHover { inside in hover(tab.id, inside) }
        .help(tab.shortcut.map { "\(tab.title) (\($0))" } ?? tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Moving between tabs hands over at once; leaving the bar waits a beat,
    /// so a pointer crossing a gap does not close and reopen a name.
    private func hover(_ id: ID, _ inside: Bool) {
        clearHover?.cancel()
        if inside {
            hovered = id
        } else if hovered == id {
            clearHover = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(90))
                if !Task.isCancelled, hovered == id { hovered = nil }
            }
        }
    }
}

private struct CollapsingTabBarGlass: ViewModifier {
    let drawsGlass: Bool

    func body(content: Content) -> some View {
        if !drawsGlass {
            content.background(Color.primary.opacity(0.07), in: Capsule())
        } else {
            content.glassEffect(in: .capsule)
        }
    }
}
