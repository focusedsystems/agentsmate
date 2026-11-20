import SwiftUI
import AppKit

// MARK: Messaging a lane from anywhere

extension AgentLaneStore {
    /// How long a lane attached only to take a message has to start its
    /// agent before the message goes on the clipboard instead.
    public static let messageAttachTimeout: Duration = .seconds(20)

    /// Attach a lane's session here without showing it: the selection,
    /// the keyboard and the visit history stay where they are.
    public func attachInBackground(_ id: AgentLane.ID) {
        guard let session = sessions[id], !session.isAttached else { return }
        start(session)
    }

    /// Type `text` into a lane's agent and press Return, from anywhere. A
    /// lane not attached here is attached in the background first, and the
    /// text waits until its agent takes a paste. When nothing takes it in
    /// time, it goes on the clipboard and the result says so.
    @discardableResult
    public func message(_ text: String, to id: AgentLane.ID,
                        timeout: Duration = AgentLaneStore.messageAttachTimeout) async -> SendResult {
        guard let session = sessions[id], !session.isAttached else { return send(text, to: id, submit: true) }
        attachInBackground(id)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var readySince: ContinuousClock.Instant?
        while clock.now < deadline, sessions[id] === session, !session.hasExited {
            if session.acceptsText {
                // An agent turns on bracketed paste as its prompt mounts;
                // give it a moment to finish drawing before typing.
                if let since = readySince, clock.now - since >= .milliseconds(400) { break }
                readySince = readySince ?? clock.now
            } else {
                readySince = nil
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return send(text, to: id, submit: true)
    }

    /// Start Message Agent for a lane, the selected one when `id` is nil:
    /// the app's message window when it registered one, else the lanes'
    /// alert. Returns false when it fell back to the alert, so a caller can
    /// bring the lanes on screen.
    @discardableResult
    public func showMessageAgent(to id: AgentLane.ID? = nil, openWindow: OpenWindowAction) -> Bool {
        let target = id ?? selectedID ?? displayOrder.first?.id
        if let target { messageTarget = target }
        if let windowID = configuration.messageWindowID {
            openWindow(id: windowID)
            return true
        }
        messageAlertTarget = target
        return false
    }
}

// MARK: The window

/// Message Agent as a small window: pick a lane, type, Return sends and ⎋
/// closes. Add it to the app's scenes and give its id to the store:
///
/// ```swift
/// AgentMessageWindow(store: store)
/// // with Configuration(…, messageWindowID: AgentMessageWindow.defaultID)
/// ```
public struct AgentMessageWindow: Scene {
    /// The id the window is registered under unless the app picks another.
    public static let defaultID = "agentsmate.message"

    let store: AgentLaneStore
    let id: String
    let title: String

    public init(store: AgentLaneStore, id: String = AgentMessageWindow.defaultID, title: String = "Message Agent") {
        self.store = store
        self.id = id
        self.title = title
    }

    public var body: some Scene {
        Window(title, id: id) {
            AgentMessageView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Message Agent in the Agent menu opens it, on its own shortcut.
        .commandsRemoved()
    }
}

/// The message window's content, for an app that hosts it in its own scene.
public struct AgentMessageView: View {
    @ObservedObject var store: AgentLaneStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var copied = false
    @FocusState private var editing: Bool

    public init(store: AgentLaneStore) {
        self.store = store
    }

    private var target: AgentLaneSession? { store.messageTarget.flatMap { store.sessions[$0] } }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("To:", selection: $store.messageTarget) {
                ForEach(store.displayOrder) { lane in
                    Text(store.sessions[lane.id]?.title ?? lane.title).tag(Optional(lane.id))
                }
            }
            .disabled(sending)
            TextField("Message", text: $text, prompt: Text("Message"), axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($editing)
                .onSubmit(send)
                .disabled(sending)
                .accessibilityLabel("Message")
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if sending {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(target?.isAttached == true ? "Sending" : "Attaching")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || target == nil || sending)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if target == nil { store.messageTarget = store.selectedID ?? store.displayOrder.first?.id }
            copied = false
            editing = true
        }
        .onChange(of: store.messageTarget) { copied = false }
    }

    private var note: String {
        if copied { return "Nothing there took the message, so it is on the clipboard." }
        guard let target else { return "Pick an agent to send to." }
        if sending, !target.isAttached { return "Attaching \(target.title)…" }
        if !target.isAttached {
            return "\(target.title) is not attached here. Sending attaches it in the background, then types the message and presses Return."
        }
        return "Typed into the agent and sent with Return. Option-Return starts a new line."
    }

    private func send() {
        let message = trimmed
        guard !message.isEmpty, !sending, let id = store.messageTarget else { return }
        sending = true
        copied = false
        Task {
            let result = await store.message(message, to: id)
            sending = false
            if result == .sent {
                text = ""
                dismiss()
            } else {
                copied = true
            }
        }
    }
}

/// Message Agent in a menu, on the person's shortcut for it (⌥⌘K unless
/// they changed it).
struct AgentMessageMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: AgentLaneStore
    let reveal: () -> Void

    var body: some View {
        Button("Message Agent…") {
            if !store.showMessageAgent(openWindow: openWindow) { reveal() }
        }
        .laneShortcut(store.shortcuts.binding(for: .messageAgent))
        .disabled(store.lanes.isEmpty)
    }
}
