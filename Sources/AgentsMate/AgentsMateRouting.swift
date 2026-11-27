import AgentsMateStatus
import AppKit

/// Where a pull request, pipeline or commit link goes when it is clicked in
/// an app's lane UI: AgentsMate.app's matching view when that app is installed
/// on this Mac, else the default browser, as before. Every click goes through
/// ``open(_:)``, so an app gets this by updating its AgentsMate pin.
public enum AgentsMateRouting {
    /// Whether AgentsMate.app is installed on this Mac.
    public static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentsMateLink.bundleID) != nil
    }

    /// Opens `url`, through AgentsMate.app when it is installed and knows the
    /// address. `appInstalled` and `opener` let a test stand in for the Mac.
    public static func open(_ url: URL,
                            appInstalled: @autoclosure () -> Bool = AgentsMateRouting.isInstalled,
                            opener: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        // Ask the Mac only for an address the app could take.
        let routed = AgentsMateLink.kind(of: url) != nil
            ? AgentsMateLink.destination(for: url, appInstalled: appInstalled())
            : url
        opener(routed)
    }
}
