import SwiftUI
import AppKit

/// A Settings section listing every lanes command with its shortcut. Click
/// a shortcut and press new keys to change it; Delete clears it, Escape
/// cancels. A shortcut another command uses is refused, with a note saying
/// which. Put it in a grouped `Form`.
public struct AgentLaneShortcutsSection: View {
    @ObservedObject var store: AgentLaneStore
    @State private var recording: LaneShortcutAction?
    @State private var message: String?

    public init(store: AgentLaneStore) { self.store = store }

    public var body: some View {
        Section {
            ForEach(LaneShortcutAction.allCases) { action in
                LabeledContent(action.title) {
                    ShortcutRecorderButton(
                        binding: store.shortcuts.binding(for: action),
                        isRecording: recording == action,
                        start: { recording = action; message = nil },
                        finish: { result in finish(action, result) })
                }
            }
            Text("⌘1 to ⌘9 and ⌃Tab always move between lanes.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            Button("Restore Default Shortcuts") {
                store.shortcuts = LaneShortcutBindings()
                message = nil
            }
            .disabled(store.shortcuts.overrides.isEmpty)
        } header: {
            Text("Keyboard Shortcuts")
        }
    }

    private func finish(_ action: LaneShortcutAction, _ result: ShortcutRecorderButton.Result) {
        recording = nil
        switch result {
        case .cancel:
            return
        case .clear:
            store.shortcuts.set(nil, for: action)
        case .set(let binding):
            if let other = store.shortcuts.conflict(for: binding, excluding: action) {
                message = "\(binding.display) is already \(other.title)."
                return
            }
            store.shortcuts.set(binding, for: action)
        }
    }
}

/// Shows a shortcut; while recording, the next key press with ⌘, ⌃ or ⌥
/// becomes it.
struct ShortcutRecorderButton: View {
    enum Result { case set(LaneKeyBinding), clear, cancel }

    let binding: LaneKeyBinding?
    let isRecording: Bool
    let start: () -> Void
    let finish: (Result) -> Void
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Type Shortcut…" : (binding?.display ?? "None")) {
            isRecording ? stop(.cancel) : begin()
        }
        .font(.body.monospaced())
        .frame(minWidth: 120)
        .accessibilityLabel(isRecording ? "Recording shortcut" : "Shortcut \(binding?.display ?? "none")")
        .accessibilityHint("Press to record a new shortcut")
        .onDisappear { removeMonitor() }
    }

    private func begin() {
        start()
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                switch event.keyCode {
                case 53: stop(.cancel)               // Escape
                case 51, 117: stop(.clear)           // Delete, Forward Delete
                default:
                    guard let pressed = LaneKeyBinding(event: event) else { NSSound.beep(); return }
                    stop(.set(pressed))
                }
            }
            return nil
        }
    }

    private func stop(_ result: Result) {
        removeMonitor()
        finish(result)
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
