import SwiftUI
import AppKit

/// How an app opens: in Agents mode, with the Agents view filling the
/// window. This happens once, when the first window appears after launch,
/// so leaving Agents mode later in the session is never undone.
///
/// The window stays out of macOS full screen: a window restored in its own
/// full-screen space is brought back to the desktop, unless the app turns
/// ``AgentsModeKeys/fullScreenAtLaunch`` on.
///
/// Launch starts no agent: no lane is created, and the terminal area shows
/// the selected lane only if its session is already running (see
/// ``AgentLaneStore/openSelectedOnShow()``).
///
/// Agents mode is on unless the store's ``AgentsModeKeys/agentsModeAtLaunch``
/// default turns it off.
@MainActor
public enum AgentsLaunch {
    /// Set once the first window has applied the launch presentation.
    static var applied = false

    /// Whether the app opens in Agents mode.
    public static func opensAgentsMode(_ keys: AgentsModeKeys, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keys.agentsModeAtLaunch) as? Bool ?? true
    }

    /// Whether the app's first window opens in macOS full screen. Off
    /// unless the default is set to true.
    public static func opensFullScreen(_ keys: AgentsModeKeys, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keys.fullScreenAtLaunch) as? Bool ?? false
    }
}

public extension AgentsModeKeys {
    var agentsModeAtLaunch: String { prefix + "agentsModeAtLaunch" }
    var fullScreenAtLaunch: String { prefix + "fullScreenAtLaunch" }
}

public extension View {
    /// Open the app the way ``AgentsLaunch`` says, the first time a window
    /// with this modifier appears in the process. `enterAgentsMode` switches
    /// the app into Agents mode; the default opens the store's dock filling
    /// the window (``AgentLaneStore/enterAgentsMode()``). Put it on the main window's root view.
    func agentsLaunch(_ store: AgentLaneStore, defaults: UserDefaults = .standard,
                      enterAgentsMode: (() -> Void)? = nil) -> some View {
        background(AgentsLaunchAnchor { window in
            guard !AgentsLaunch.applied else { return }
            AgentsLaunch.applied = true
            if AgentsLaunch.opensAgentsMode(store.keys, defaults: defaults) {
                if let enterAgentsMode { enterAgentsMode() } else { store.enterAgentsMode() }
            }
            AgentsLaunch.setFullScreen(window, AgentsLaunch.opensFullScreen(store.keys, defaults: defaults))
        })
    }
}

extension AgentsLaunch {
    /// Put the window in or out of its own full-screen space, whichever
    /// `on` says, when it is not there already (restored either way).
    static func setFullScreen(_ window: NSWindow, _ on: Bool) {
        // Wait for the window to be on screen; toggling one still being
        // ordered in leaves it zoomed rather than in its own space.
        Task { @MainActor in
            for _ in 0..<50 where !window.isVisible {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard window.isVisible, window.styleMask.contains(.fullScreen) != on else { return }
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
