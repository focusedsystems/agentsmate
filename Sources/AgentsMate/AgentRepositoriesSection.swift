import SwiftUI

/// One repository in ``AgentRepositoriesSection``: its folder, and what the
/// row shows.
public struct AgentRepositoryItem: Identifiable, Hashable, Sendable {
    /// The repository's folder; the key the order is kept by.
    public var path: String
    public var title: String
    /// A second line, such as the section it is listed under or its remote.
    public var subtitle: String?
    public var icon: LaneIcon?
    public var tintHex: String?

    public var id: String { path }

    public init(path: String, title: String, subtitle: String? = nil, icon: LaneIcon? = nil, tintHex: String? = nil) {
        self.path = path
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tintHex = tintHex
    }
}

/// A Settings section listing an app's repositories in the one repository
/// order: the order of the sidebar's repository headings, and the order the
/// app gives any other list of repositories (``AgentLaneStore/orderedRepositories(_:)``).
/// Dragging a row reorders the headings, and moving a heading reorders the
/// rows. Reset to Default Order goes back to the app's order
/// (``AgentLaneStore/defaultRepositoryOrder``).
///
/// The app supplies the repositories, the buttons beside Reset at the top
/// (add, sync) and anything a row carries at its end (per-repository options).
/// Put it in a grouped `Form`.
public struct AgentRepositoriesSection<Buttons: View, RowAccessory: View>: View {
    @ObservedObject var store: AgentLaneStore
    let items: [AgentRepositoryItem]
    let title: String
    let footer: String?
    let onReset: (() -> Void)?
    let buttons: Buttons
    let accessory: (AgentRepositoryItem) -> RowAccessory

    /// `onReset` runs after the order is reset, for an app whose own reset
    /// (back to its registry, say) is the same action.
    public init(store: AgentLaneStore, items: [AgentRepositoryItem], title: String = "Repositories",
                footer: String? = nil, onReset: (() -> Void)? = nil,
                @ViewBuilder buttons: () -> Buttons,
                @ViewBuilder accessory: @escaping (AgentRepositoryItem) -> RowAccessory) {
        self.store = store
        self.items = items
        self.title = title
        self.footer = footer
        self.onReset = onReset
        self.buttons = buttons()
        self.accessory = accessory
    }

    private var ordered: [AgentRepositoryItem] {
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return store.orderedRepositories(items.map(\.path)).compactMap { byPath[$0] }
    }

    public var body: some View {
        let rows = ordered
        Section {
            HStack(spacing: 8) {
                buttons
                Spacer()
                Button("Reset to Default Order") {
                    store.resetRepositoryOrder()
                    onReset?()
                }
                .disabled(!store.hasCustomRepositoryOrder && onReset == nil)
                .help("Put the repositories back in the app's order")
            }
            List {
                ForEach(rows) { item in
                    row(item)
                }
                .onMove { source, destination in
                    var paths = rows.map(\.path)
                    paths.move(fromOffsets: source, toOffset: destination)
                    store.setRepositoryOrder(paths)
                }
            }
            .frame(minHeight: 160, idealHeight: CGFloat(min(rows.count, 12)) * 34 + 8)
        } header: {
            Text(title)
        } footer: {
            Text(footer ?? "Drag to reorder. This order is the order of the sidebar's repository headings and of every repository list in the app.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ item: AgentRepositoryItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            if let icon = item.icon {
                LaneIconView(icon: icon, tintHex: item.tintHex, size: 14).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            accessory(item)
        }
        .contextMenu {
            let order = rows(ordered)
            Button("Move Up") { move(item, by: -1, in: order) }.disabled(order.first == item.path)
            Button("Move Down") { move(item, by: 1, in: order) }.disabled(order.last == item.path)
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            let order = rows(ordered)
            Button("Move Up") { move(item, by: -1, in: order) }
            Button("Move Down") { move(item, by: 1, in: order) }
        }
    }

    private func rows(_ items: [AgentRepositoryItem]) -> [String] { items.map(\.path) }

    private func move(_ item: AgentRepositoryItem, by offset: Int, in order: [String]) {
        var paths = order
        guard let index = paths.firstIndex(of: item.path) else { return }
        let target = min(max(index + offset, 0), paths.count - 1)
        guard target != index else { return }
        paths.remove(at: index)
        paths.insert(item.path, at: target)
        store.setRepositoryOrder(paths)
    }
}

public extension AgentRepositoriesSection where RowAccessory == EmptyView {
    init(store: AgentLaneStore, items: [AgentRepositoryItem], title: String = "Repositories",
         footer: String? = nil, onReset: (() -> Void)? = nil, @ViewBuilder buttons: () -> Buttons) {
        self.init(store: store, items: items, title: title, footer: footer, onReset: onReset,
                  buttons: buttons, accessory: { _ in EmptyView() })
    }
}
