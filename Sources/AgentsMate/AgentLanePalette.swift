import SwiftUI

/// Go to Lane…: type part of a lane's name, folder, branch or section, move
/// with the arrow keys, and Return shows it. Escape closes. Attached to
/// ``AgentLaneDetail`` and ``AgentLaneInspector`` so it is there wherever
/// the lanes are on screen.
struct AgentLanePalette: View {
    @ObservedObject var store: AgentLaneStore
    @State private var query = ""
    @State private var highlighted: AgentLane.ID?
    @FocusState private var fieldFocused: Bool

    private var results: [AgentLane] { store.paletteResults(query) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Go to lane", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { store.paletteVisible = false; return .handled }
            Divider()
            List(selection: $highlighted) {
                ForEach(results) { lane in
                    if let session = store.sessions[lane.id] {
                        HStack {
                            Image(systemName: lane.symbol)
                            VStack(alignment: .leading) {
                                Text(session.title)
                                Text(session.shortDirectory).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(session.status.title).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(lane.id)
                    }
                }
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: AgentLane.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first { show(id) }
            }
        }
        .frame(width: 480, height: 360)
        .onAppear {
            fieldFocused = true
            highlighted = results.first?.id
        }
        .onChange(of: query) { _, _ in highlighted = results.first?.id }
    }

    private func move(_ step: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        let index = highlighted.flatMap { ids.firstIndex(of: $0) } ?? -1
        highlighted = ids[min(max(index + step, 0), ids.count - 1)]
    }

    private func openHighlighted() {
        if let id = highlighted ?? results.first?.id { show(id) }
    }

    private func show(_ id: AgentLane.ID) {
        store.paletteVisible = false
        store.open(id)
    }
}

extension View {
    func agentLanePalette(_ store: AgentLaneStore) -> some View {
        sheet(isPresented: Binding(get: { store.paletteVisible }, set: { store.paletteVisible = $0 })) {
            AgentLanePalette(store: store)
        }
    }
}
