import SwiftUI
import AgentsMateStatus

/// Where a lane sits in the inbox.
public enum AgentInboxSection: Sendable, Equatable {
    /// Asking a question or permission, or flagged and not yet read.
    case askingYou
    /// Finished a turn, or found idle by a daemon's session list.
    case finished

    /// The section for a lane's status and unread mark, or nil for a lane
    /// that is not waiting on anyone.
    public static func of(status: LaneDisplayStatus, unread: Bool) -> AgentInboxSection? {
        if status == .waitingForInput || status == .permissionRequested || unread { return .askingYou }
        if status == .done || status == .idle { return .finished }
        return nil
    }
}

extension AgentLaneStore {
    /// The lanes the inbox lists under Asking You, in the list's order.
    public var inboxAsking: [AgentLaneSession] { inbox(.askingYou) }
    /// The lanes the inbox lists under Finished, in the list's order.
    public var inboxFinished: [AgentLaneSession] { inbox(.finished) }

    private func inbox(_ section: AgentInboxSection) -> [AgentLaneSession] {
        displayOrder.compactMap { sessions[$0.id] }
            .filter { AgentInboxSection.of(status: $0.status, unread: $0.needsAttention) == section }
    }

    /// Clear a lane's unread mark without showing it.
    public func markRead(_ id: AgentLane.ID) {
        guard let session = sessions[id], session.needsAttention else { return }
        objectWillChange.send()
        session.markRead()
        updateBadge()
    }

    /// Clear every lane's unread mark.
    public func markAllRead() {
        let unread = sessions.values.filter(\.needsAttention)
        guard !unread.isEmpty else { return }
        objectWillChange.send()
        unread.forEach { $0.markRead() }
        updateBadge()
    }

    /// Open a pull request link the agent posted, through
    /// ``onOpenPullRequest`` or else the default browser. A link that is
    /// not a trusted pull request address (``PullRequestLink/isTrusted(_:)``)
    /// is never opened or handed to the hook; the result is then false.
    @discardableResult
    public func openPullRequest(_ url: URL) -> Bool {
        guard PullRequestLink.isTrusted(url) else { return false }
        if let onOpenPullRequest { onOpenPullRequest(url) } else { NSWorkspace.shared.open(url) }
        return true
    }
}

/// A pull request link as a chip shows it: its number, from a GitHub
/// (`…/pull/12`) or Azure DevOps (`…/pullrequest/12`) address.
public enum PullRequestLinkLabel {
    public static func number(of url: URL) -> Int? {
        let parts = url.pathComponents
        guard let index = parts.lastIndex(where: { ["pull", "pulls", "pullrequest", "merge_requests"].contains($0.lowercased()) }),
              index + 1 < parts.count else { return nil }
        return Int(parts[index + 1])
    }

    public static func title(of url: URL) -> String {
        number(of: url).map { "#\($0)" } ?? url.lastPathComponent
    }
}

/// Every lane whose agent has stopped for the person, in one place: those
/// asking (a question, a permission prompt, or a notification not yet
/// read) above those that finished a turn. Each shows its summary, what the
/// agent last said and the pull requests it posted; a reply typed here goes
/// to that agent without switching to it. Double-click or Return shows the
/// lane. Put it in its own window scene.
public struct AgentInboxView: View {
    @ObservedObject var store: AgentLaneStore
    let onShow: (AgentLane.ID) -> Void
    @State private var selection: AgentLane.ID?

    /// `onShow` brings a lane forward in the app (Agents mode, the dock).
    public init(store: AgentLaneStore, onShow: @escaping (AgentLane.ID) -> Void = { _ in }) {
        self.store = store
        self.onShow = onShow
    }

    public var body: some View {
        let asking = store.inboxAsking
        let finished = store.inboxFinished
        Group {
            if asking.isEmpty && finished.isEmpty {
                ContentUnavailableView("Nothing Waiting", systemImage: "tray",
                                       description: Text("Agents that ask you something or finish a turn show here."))
            } else {
                List(selection: $selection) {
                    if !asking.isEmpty {
                        Section("Asking You") {
                            ForEach(asking) { InboxRow(session: $0, store: store, onShow: show).tag($0.id) }
                        }
                    }
                    if !finished.isEmpty {
                        Section("Finished") {
                            ForEach(finished) { InboxRow(session: $0, store: store, onShow: show).tag($0.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: AgentLane.ID.self) { ids in
                    if let id = ids.first, let session = store.sessions[id] {
                        InboxRowMenu(session: session, store: store, onShow: show)
                    }
                } primaryAction: { ids in
                    if let id = ids.first { show(id) }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .focusedSceneValue(\.agentInboxSelection, selection)
        .toolbar {
            ToolbarItem {
                Button {
                    store.markAllRead()
                } label: {
                    Label("Mark All Read", systemImage: "checkmark.circle")
                }
                .help("Clear every unread mark")
                .disabled(store.unreadLanes.isEmpty)
            }
        }
    }

    private func show(_ id: AgentLane.ID) {
        store.open(id)
        onShow(id)
    }
}

/// The inbox row's contextual menu.
private struct InboxRowMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var session: AgentLaneSession
    let store: AgentLaneStore
    let onShow: (AgentLane.ID) -> Void

    var body: some View {
        Button("Show") { onShow(session.id) }
        Button("Mark Read") { store.markRead(session.id) }
            .disabled(!session.needsAttention)
        Button("Mark All Read") { store.markAllRead() }
            .disabled(store.unreadLanes.isEmpty)
        Divider()
        if store.configuration.messageWindowID != nil {
            Button("Message…") { store.showMessageAgent(to: session.id, openWindow: openWindow) }
        }
        if !session.pullRequestLinks.isEmpty {
            Divider()
            ForEach(session.pullRequestLinks, id: \.self) { url in
                Button("Open Pull Request \(PullRequestLinkLabel.title(of: url))") { store.openPullRequest(url) }
            }
        }
        Divider()
        if let message = session.record?.message {
            Button("Copy Message") { copy(message) }
        }
        if store.summariesAvailable {
            Button("Copy Summary") { store.copySummary(of: session.id) }
                .disabled(session.summary?.isEmpty ?? true)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
                LaneIconView(icon: session.icon, tintHex: session.tintHex, size: 16)
                    .accessibilityHidden(true)
                Text(session.title).font(.headline)
                Text(session.status.title).font(.caption).foregroundStyle(.secondary)
                if session.needsAttention {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.tint)
                        .help("Unread")
                        .accessibilityLabel("Unread")
                }
                Spacer()
                if let at = session.record?.updatedAt {
                    Text(at, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                Button("Show") { onShow(session.id) }
                    .help("Show this agent's terminal")
            }
            if let summary = session.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .lineLimit(2)
            }
            if let message = session.record?.message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if !session.pullRequestLinks.isEmpty {
                HStack(spacing: 4) {
                    ForEach(session.pullRequestLinks.suffix(6), id: \.self) { url in
                        PullRequestChip(url: url) { store.openPullRequest(url) }
                    }
                }
            }
            HStack {
                TextField("Reply", text: $reply)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .accessibilityLabel("Reply to \(session.title)")
                Button("Send", action: send)
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if copied {
                Text("No agent took the reply, so it is on the clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.title)
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            copied = await store.message(text, to: session.id) == .copied
            if !copied { reply = "" }
        }
    }
}

/// One pull request link the agent posted, as a button that opens it.
struct PullRequestChip: View {
    let url: URL
    let open: () -> Void

    var body: some View {
        let title = PullRequestLinkLabel.title(of: url)
        Button(action: open) {
            Label(title, systemImage: "arrow.triangle.pull")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .help(url.absoluteString)
        .accessibilityLabel("Pull request \(title.hasPrefix("#") ? String(title.dropFirst()) : title)")
        .accessibilityHint("Opens it in the browser")
    }
}

struct AgentInboxSelectionKey: FocusedValueKey {
    typealias Value = AgentLane.ID
}

extension FocusedValues {
    /// The row selected in a focused inbox window, for the menu bar's Mark Read.
    var agentInboxSelection: AgentLane.ID? {
        get { self[AgentInboxSelectionKey.self] }
        set { self[AgentInboxSelectionKey.self] = newValue }
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
        let waiting = store.inboxAsking.count
        Button(waiting > 0 ? "Agent Inbox (\(waiting))" : "Agent Inbox") { openWindow(id: windowID) }
            .keyboardShortcut("i", modifiers: [.command, .shift])
    }
}

/// The inbox as a toolbar-sized button with a badge counting the lanes
/// asking for the person. The lane sidebar puts one at its foot when
/// `Configuration.inboxWindowID` is set.
public struct AgentInboxButton: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: AgentLaneStore
    let windowID: String

    public init(store: AgentLaneStore, windowID: String) {
        self.store = store
        self.windowID = windowID
    }

    public var body: some View {
        let count = store.inboxAsking.count
        Button { openWindow(id: windowID) } label: {
            Image(systemName: count > 0 ? "tray.full" : "tray")
                .font(.system(size: 13))
                .frame(width: 24, height: 22)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 5, y: -4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(count > 0 ? "Agent Inbox: \(count) asking you (⇧⌘I)" : "Agent Inbox (⇧⌘I)")
        .accessibilityLabel("Agent Inbox")
        .accessibilityValue(count == 1 ? "1 asking you" : "\(count) asking you")
        .contextMenu {
            Button("Open Agent Inbox") { openWindow(id: windowID) }
            Button("Mark All Read") { store.markAllRead() }
                .disabled(store.unreadLanes.isEmpty)
        }
    }
}
