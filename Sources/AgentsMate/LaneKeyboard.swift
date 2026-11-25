import SwiftUI
import AppKit

/// Where the keyboard is, as far as the lanes care: whether a lane's
/// terminal or the lane list has it. The Reopen As keys belong to the lanes
/// only then, so an app keeps the same keys for its own views elsewhere.
@MainActor
final class LaneKeyboardTracker {
    private var notes: [NSObjectProtocol] = []
    private var monitor: Any?
    private let lists = NSHashTable<LaneListKeysView>.weakObjects()
    var onChange: (() -> Void)?

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSMenu.didBeginTrackingNotification] {
            notes.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
    }

    /// Follow where the keyboard goes in `window`: clicks and key presses
    /// move it, so each is checked once it has been handled. Safe to call
    /// again for the same window.
    func watch(_ window: NSWindow?) {
        guard let window else { return }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onChange?() } }
                return event
            }
        }
        onChange?()
    }

    func register(_ list: LaneListKeysView) {
        lists.add(list)
        watch(list.window)
    }

    /// Whether the key window's first responder is one of `terminals` or a
    /// lane list.
    func keyboardIsInLanes(terminals: [NSView]) -> Bool {
        guard let window = NSApp?.keyWindow, let responder = window.firstResponder else { return false }
        if let view = responder as? NSView, terminals.contains(where: { $0 === view }) { return true }
        return lists.allObjects.contains { $0.window === window && $0.listHasKeyboard }
    }
}

extension AgentLaneStore {
    /// Recheck where the keyboard is. The terminal hosts and the lane list
    /// call it as they come and go; window focus changes call it too.
    func updateLanesHaveKeyboard() {
        let now = keyboard.keyboardIsInLanes(terminals: sessions.values.map(\.view))
        if now != lanesHaveKeyboard { lanesHaveKeyboard = now }
    }
}

/// Reopen As for the selected lane: one item per choice the app offers,
/// each kind on its shortcut while the lanes have the keyboard, and the
/// whole menu disabled while no lane is selected. The Agent menu shows it;
/// an app with a menu of its own can put it there instead.
public struct LaneReopenMenu: View {
    @ObservedObject var store: AgentLaneStore
    let title: String
    let reveal: () -> Void

    public init(store: AgentLaneStore, title: String = "Reopen As", reveal: @escaping () -> Void = {}) {
        self.store = store
        self.title = title
        self.reveal = reveal
    }

    public var body: some View {
        if !store.configuration.reopenChoices.isEmpty {
            Menu(title) {
                ForEach(Array(store.configuration.reopenChoices.enumerated()), id: \.offset) { index, choice in
                    Button(choice.title) {
                        reveal()
                        store.reopenSelected(choice: index)
                    }
                    .laneShortcut(store.reopenMenuBinding(for: choice))
                }
            }
            .disabled(store.selectedID == nil)
        }
    }
}

extension AgentLaneStore {
    /// The key a Reopen As menu item shows: the choice's kind's binding while
    /// the lanes have the keyboard, else none, so the same keys stay free for
    /// the app's own views. A focused terminal or lane list takes the keys
    /// itself either way.
    public func reopenMenuBinding(for choice: LaneReopenChoice) -> LaneKeyBinding? {
        // Claude and Codex (remote) are Switch to Claude and Switch to Codex on
        // the lane's menu, which owns ⇧⌘C and ⇧⌘X in every app.
        guard lanesHaveKeyboard, configuration.shortcuts.contains(.reopen), let kind = choice.kind,
              kind != .claudeRemote, kind != .codexRemote else { return nil }
        return shortcuts.binding(for: kind.shortcutAction)
    }
}
