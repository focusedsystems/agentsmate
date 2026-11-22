import SwiftUI
import AppKit

/// How an app opens: in Agents mode, with its window in macOS full screen.
/// Both happen once, when the first window appears after launch, so leaving
/// Agents mode or full screen later in the session is never undone.
///
/// Both are on unless the person turns them off with the store's
/// ``AgentsModeKeys/agentsModeAtLaunch`` and
/// ``AgentsModeKeys/fullScreenAtLaunch`` defaults.
@MainActor
public enum AgentsLaunch {
    /// Set once the first window has applied the launch presentation.
    static var applied = false

    /// Whether the app opens in Agents mode.
    public static func opensAgentsMode(_ keys: AgentsModeKeys, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keys.agentsModeAtLaunch) as? Bool ?? true
    }

    /// Whether the app's first window opens in full screen.
    public static func opensFullScreen(_ keys: AgentsModeKeys, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keys.fullScreenAtLaunch) as? Bool ?? true
    }
}

public extension AgentsModeKeys {
    var agentsModeAtLaunch: String { prefix + "agentsModeAtLaunch" }
    var fullScreenAtLaunch: String { prefix + "fullScreenAtLaunch" }
}

public extension AgentLaneStore {
    /// Agents mode for an app that shows its lanes in ``AgentLaneDock``: the
    /// dock open and filling the window.
    func enterAgentsMode() {
        if !dockVisible { showDock() }
        dockMaximized = true
    }
}

public extension View {
    /// Open the app the way ``AgentsLaunch`` says, the first time a window
    /// with this modifier appears in the process. `enterAgentsMode` switches
    /// the app into Agents mode; the default opens the store's dock filling
    /// the window. Put it on the main window's root view.
    func agentsLaunch(_ store: AgentLaneStore, defaults: UserDefaults = .standard,
                      enterAgentsMode: (() -> Void)? = nil) -> some View {
        background(AgentsLaunchAnchor { window in
            guard !AgentsLaunch.applied else { return }
            AgentsLaunch.applied = true
            if AgentsLaunch.opensAgentsMode(store.keys, defaults: defaults) {
                if let enterAgentsMode { enterAgentsMode() } else { store.enterAgentsMode() }
            }
            if AgentsLaunch.opensFullScreen(store.keys, defaults: defaults) {
                AgentsLaunch.enterFullScreen(window)
            }
        })
    }
}

extension AgentsLaunch {
    /// Put the window in its own full-screen space, unless it is there
    /// already (restored that way, say).
    static func enterFullScreen(_ window: NSWindow) {
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Wait for the window to be on screen; toggling one still being
        // ordered in leaves it zoomed rather than in its own space.
        Task { @MainActor in
            for _ in 0..<50 where !window.isVisible {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }
}

/// Finds the window a SwiftUI view is in and reports it once.
private struct AgentsLaunchAnchor: NSViewRepresentable {
    let found: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.found = found
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        var found: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let found else { return }
            self.found = nil
            DispatchQueue.main.async { found(window) }
        }
    }
}
