import SwiftUI

/// One lane's terminal in a narrow side column, such as a window's
/// inspector: a menu at the top picks the lane, the terminal fills the rest.
/// It shows the same session as the sidebar mode, so a window can offer
/// either; the two must not be on screen at once, because one terminal view
/// can be in only one place.
public struct AgentLaneInspector<Empty: View>: View {
    @ObservedObject var store: AgentLaneStore
    let labels: AgentsModeLabels
    let empty: Empty

    public init(store: AgentLaneStore, labels: AgentsModeLabels = .init(), @ViewBuilder empty: () -> Empty) {
        self.store = store
        self.labels = labels
        self.empty = empty()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.lanes.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let session = store.selected {
                LaneTerminalPane(session: session, store: store)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .agentLanePalette(store)
        .onAppear {
            store.isShowing = true
            store.openSelected(focus: false)
        }
        .onDisappear { store.isShowing = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Array(store.lanes.enumerated()), id: \.element.id) { index, lane in
                    Button {
                        store.open(lane.id)
                    } label: {
                        if let session = store.sessions[lane.id] {
                            Text("\(session.title) — \(session.status.title)")
                        } else {
                            Text(lane.title)
                        }
                    }
                }
            } label: {
                if let session = store.selected {
                    HStack(spacing: 6) {
                        LaneIconView(icon: session.icon, tintHex: session.tintHex, size: 14)
                        Text(session.title)
                    }
                } else {
                    Text("Choose \(labels.laneNoun.capitalized)")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.lanes.isEmpty)
            .help("Choose which \(labels.laneNoun)'s agent to show")
            if let session = store.selected {
                InspectorStatus(session: session)
            }
            Spacer()
            if let id = store.selectedID {
                Button {
                    store.reattach(id)
                } label: {
                    Label("Reattach", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Reattach (⇧⌘R)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct InspectorStatus: View {
    @ObservedObject var session: AgentLaneSession

    var body: some View {
        Text(session.isOrphan && !session.isAttached ? "Running, nothing attached" : session.status.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
