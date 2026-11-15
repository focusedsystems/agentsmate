import SwiftUI
import AgentsMateStatus

/// Every lane whose agent has stopped for the person, in one place: those
/// asking (a question or a permission prompt) above those that finished a
/// turn. Each shows what the agent last said; a reply typed here goes to
/// that agent without switching to it. Put it in its own window scene.
public struct AgentInboxView: View {
    @ObservedObject var store: AgentLaneStore
    let onShow: (AgentLane.ID) -> Void

    /// `onShow` brings a lane forward in the app (Agents mode, the dock).
    public init(store: AgentLaneStore, onShow: @escaping (AgentLane.ID) -> Void = { _ in }) {
        self.store = store
        self.onShow = onShow
    }

    private var sessions: [AgentLaneSession] { store.displayOrder.compactMap { store.sessions[$0.id] } }
    private var asking: [AgentLaneSession] {
        sessions.filter { $0.status == .waitingForInput || $0.status == .permissionRequested }
    }
    private var finished: [AgentLaneSession] { sessions.filter { $0.status == .done } }

    public var body: some View {
        Group {
            if asking.isEmpty && finished.isEmpty {
                ContentUnavailableView("Nothing Waiting", systemImage: "tray",
                                       description: Text("Agents that ask you something or finish a turn show here."))
            } else {
                List {
                    if !asking.isEmpty {
                        Section("Asking You") {
                            ForEach(asking) { InboxRow(session: $0, store: store, onShow: onShow) }
                        }
                    }
                    if !finished.isEmpty {
                        Section("Finished") {
                            ForEach(finished) { InboxRow(session: $0, store: store, onShow: onShow) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

private struct InboxRow: View {
    @ObservedObject var session: AgentLaneSession
    let store: AgentLaneStore
    let onShow: (AgentLane.ID) -> Void
    @State private var reply = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: session.lane.symbol)
                    .foregroundStyle(session.lane.tintHex.flatMap(Color.init(laneHex:)) ?? Color.accentColor)
                Text(session.title).font(.headline)
                Text(session.status.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let at = session.record?.updatedAt {
                    Text(at, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                Button("Show") {
                    store.open(session.id)
                    onShow(session.id)
                }
                .help("Show this agent's terminal")
            }
            if let message = session.record?.message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack {
                TextField("Reply", text: $reply)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if copied {
                Text("No agent is running there, so the reply is on the clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show") { store.open(session.id); onShow(session.id) }
            if let message = session.record?.message {
                Button("Copy Message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
            }
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        copied = store.send(text, to: session.id, submit: true) == .copied
        if !copied { reply = "" }
    }
}

/// The lanes menu item that opens the inbox window, for an app that adds
/// a `Window` scene with ``AgentInboxView`` under `windowID`.
public struct AgentInboxMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: AgentLaneStore
    let windowID: String

    public init(store: AgentLaneStore, windowID: String) {
        self.store = store
        self.windowID = windowID
    }

    public var body: some View {
        let waiting = store.lanes.compactMap { store.sessions[$0.id] }
            .filter { [.waitingForInput, .permissionRequested].contains($0.status) }.count
        Button(waiting > 0 ? "Agent Inbox (\(waiting))" : "Agent Inbox") { openWindow(id: windowID) }
            .keyboardShortcut("i", modifiers: [.command, .shift])
    }
}
