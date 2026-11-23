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

/// A Settings section listing an app's repositories in the list's order:
/// by section, then within each section, the same order the sidebar shows.
/// Dragging a section or a repository reorders the sidebar, and moving a
/// section or a row there reorders this list. Reset to Default Order goes
/// back to the app's order (``AgentLaneStore/defaultRepositoryOrder``). An
/// app whose list has no section headings
/// (``AgentLaneStore/Configuration/showsSectionHeadings``, or the person's
/// choice in ``AgentSidebarSettingsSection``) gets one list. Repositories in
/// no section come first, with no heading.
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
    @AppStorage private var showsHeadings: Bool

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
        _showsHeadings = AppStorage(wrappedValue: store.sidebarDefaults.headings, store.keys.showsSectionHeadings)
    }

    /// One section of the list: its name (nil for repositories in none) and
    /// its repositories in order.
    struct Group: Identifiable {
        var name: String?
        var items: [AgentRepositoryItem]
        var id: String { name ?? "\u{1}none" }
    }

    private var groups: [Group] {
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = store.orderedRepositories(items.map(\.path)).compactMap { byPath[$0] }
        var members: [String: [AgentRepositoryItem]] = [:]
        var loose: [AgentRepositoryItem] = []
        for item in ordered {
            if let name = store.section(ofRepository: item.path) { members[name, default: []].append(item) } else { loose.append(item) }
        }
        // Repositories in no section lead, as they do in the sidebar.
        var out = loose.isEmpty ? [] : [Group(name: nil, items: loose)]
        out += store.sectionNames.compactMap { name in members[name].map { Group(name: name, items: $0) } }
        return out
    }

    private var sectioned: Bool {
        showsHeadings && groups.filter { $0.name != nil }.count > 1
    }

    public var body: some View {
        let groups = groups
        let sectioned = sectioned
        Section {
            HStack(spacing: 8) {
                buttons
                Spacer()
                Button("Reset to Default Order") {
                    store.resetRepositoryOrder()
                    onReset?()
                }
                .disabled(!store.hasCustomRepositoryOrder && onReset == nil)
                .help("Put the sections and repositories back in the app's order")
            }
            List {
                if sectioned {
                    ForEach(groups) { group in
                        if group.name == nil {
                            Section { repositories(group.items) }
                        } else {
                            Section {
                                repositories(group.items)
                            } header: {
                                sectionHeader(group, in: groups)
                            }
                        }
                    }
                } else {
                    repositories(groups.flatMap(\.items))
                }
            }
            .frame(minHeight: 200, idealHeight: CGFloat(min(items.count + groups.count, 14)) * 30 + 8)
        } header: {
            Text(title)
        } footer: {
            Text(footer ?? (sectioned
                ? "Drag a repository to reorder it within its section; use a section's menu to move the section. This is the sidebar's order and the order of every repository list in the app."
                : "Drag to reorder. This is the sidebar's order and the order of every repository list in the app."))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ group: Group, in groups: [Group]) -> some View {
        let names = groups.compactMap(\.name)
        HStack {
            Text(group.name ?? "")
            Spacer()
            if let name = group.name {
                Button { moveSection(name, by: -1, in: names) } label: {
                    Label("Move \(name) Up", systemImage: "chevron.up").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(names.first == name)
                .help("Move the \(name) section up")
                Button { moveSection(name, by: 1, in: names) } label: {
                    Label("Move \(name) Down", systemImage: "chevron.down").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(names.last == name)
                .help("Move the \(name) section down")
            }
        }
        .contextMenu {
            if let name = group.name {
                Button("Move Section Up") { moveSection(name, by: -1, in: names) }.disabled(names.first == name)
                Button("Move Section Down") { moveSection(name, by: 1, in: names) }.disabled(names.last == name)
            }
        }
    }

    private func repositories(_ rows: [AgentRepositoryItem]) -> some View {
        ForEach(rows) { item in
            row(item, in: rows)
        }
        .onMove { source, destination in
            var paths = rows.map(\.path)
            paths.move(fromOffsets: source, toOffset: destination)
            store.setRepositoryOrder(paths)
        }
    }

    private func row(_ item: AgentRepositoryItem, in rows: [AgentRepositoryItem]) -> some View {
        let order = rows.map(\.path)
        return HStack(spacing: 8) {
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
            Button("Move Up") { move(item, by: -1, in: order) }.disabled(order.first == item.path)
            Button("Move Down") { move(item, by: 1, in: order) }.disabled(order.last == item.path)
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Move Up") { move(item, by: -1, in: order) }
            Button("Move Down") { move(item, by: 1, in: order) }
        }
    }

    private func move(_ item: AgentRepositoryItem, by offset: Int, in order: [String]) {
        var paths = order
        guard let index = paths.firstIndex(of: item.path) else { return }
        let target = min(max(index + offset, 0), paths.count - 1)
        guard target != index else { return }
        paths.remove(at: index)
        paths.insert(item.path, at: target)
        store.setRepositoryOrder(paths)
    }

    private func moveSection(_ name: String, by offset: Int, in names: [String]) {
        var all = names
        guard let index = all.firstIndex(of: name) else { return }
        let target = min(max(index + offset, 0), all.count - 1)
        guard target != index else { return }
        all.remove(at: index)
        all.insert(name, at: target)
        store.setSectionOrder(all)
    }
}

public extension AgentRepositoriesSection where RowAccessory == EmptyView {
    init(store: AgentLaneStore, items: [AgentRepositoryItem], title: String = "Repositories",
         footer: String? = nil, onReset: (() -> Void)? = nil, @ViewBuilder buttons: () -> Buttons) {
        self.init(store: store, items: items, title: title, footer: footer, onReset: onReset,
                  buttons: buttons, accessory: { _ in EmptyView() })
    }
}
