import Foundation

/// The links AgentsMate.app opens: `agentsmate://pull?url=<encoded>`, with
/// `pull`, `pipeline` or `commit` for the host, and the GitHub or Azure DevOps
/// address it stands for in `url`. The app takes only an address of exactly
/// the shape of one of those three, so a link from a transcript or another
/// app cannot make it open or load anything else.
public enum AgentsMateLink {
    public static let scheme = "agentsmate"
    /// The bundle id of AgentsMate.app, which registers the scheme.
    public static let bundleID = "systems.focused.agentsmate"

    public enum Kind: String, CaseIterable, Sendable {
        case pull, pipeline, commit
    }

    private static let label = "[A-Za-z0-9-]+"
    private static let name = "[A-Za-z0-9._-]+"
    private static let segment = "[A-Za-z0-9._~%-]+"
    private static let sha = "[0-9a-fA-F]{7,40}"

    private static func anchored(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants, so they always compile.
        try! NSRegularExpression(pattern: "^" + pattern + "$")
    }

    private static let githubPaths: [(Kind, NSRegularExpression)] = [
        (.pull, anchored("/\(label)/\(name)/pull/[0-9]+(?:/[a-z]+)?")),
        (.pipeline, anchored("/\(label)/\(name)/actions/runs/[0-9]+(?:/job/[0-9]+)?")),
        (.commit, anchored("/\(label)/\(name)/commit/\(sha)")),
    ]
    private static let azurePaths: [(Kind, NSRegularExpression)] = [
        (.pull, anchored("(?:/\(segment))+/_git/\(segment)/pullrequest/[0-9]+")),
        (.pipeline, anchored("(?:/\(segment))+/_build/results")),
        (.commit, anchored("(?:/\(segment))+/_git/\(segment)/commit/\(sha)")),
    ]
    private static let githubHost = anchored(#"github\.com"#)
    private static let azureHost = anchored(#"dev\.azure\.com|\#(label)\.visualstudio\.com"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// What a GitHub or Azure DevOps address is, or nil for anything else.
    public static func kind(of web: URL) -> Kind? {
        guard web.scheme == "https", web.user == nil, web.password == nil, web.port == nil,
              web.fragment == nil, let host = web.host(percentEncoded: true)?.lowercased() else { return nil }
        let path = web.path(percentEncoded: true)
        let paths: [(Kind, NSRegularExpression)]
        if matches(githubHost, host) { paths = githubPaths } else if matches(azureHost, host) { paths = azurePaths } else { return nil }
        guard let found = paths.first(where: { matches($0.1, path) })?.0 else { return nil }
        // Only a build's address carries a query, its build id.
        if web.query != nil, found != .pipeline { return nil }
        return found
    }

    /// The `agentsmate://` link that opens `web` in the app.
    public static func appURL(for web: URL) -> URL? {
        guard let kind = kind(of: web) else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = kind.rawValue
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        parts.percentEncodedQueryItems = [
            URLQueryItem(name: "url", value: web.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed)),
        ]
        return parts.url
    }

    /// The address and kind an `agentsmate://` link carries, only when both
    /// agree and the address is one the app accepts.
    public static func parse(_ link: URL) -> (kind: Kind, web: URL)? {
        guard link.scheme?.lowercased() == scheme, let host = link.host?.lowercased(), let kind = Kind(rawValue: host),
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "url" })?.value,
              let web = URL(string: value), Self.kind(of: web) == kind else { return nil }
        return (kind, web)
    }

    /// Where a click on `web` goes: the app's link when AgentsMate.app is
    /// installed and knows the address, else the address itself, as before.
    public static func destination(for web: URL, appInstalled: Bool) -> URL {
        guard appInstalled, let link = appURL(for: web) else { return web }
        return link
    }

    /// What names the thing in the address: the pull request number or the
    /// commit's hash. A build has no such text, so nil.
    public static func identifier(of web: URL) -> String? {
        guard let kind = kind(of: web) else { return nil }
        let parts = web.path(percentEncoded: true).split(separator: "/").map(String.init)
        switch kind {
        case .pull:
            guard let at = parts.lastIndex(where: { $0 == "pull" || $0 == "pullrequest" }), at + 1 < parts.count else { return nil }
            return parts[at + 1]
        case .commit:
            guard let at = parts.lastIndex(of: "commit"), at + 1 < parts.count else { return nil }
            return parts[at + 1].lowercased()
        case .pipeline:
            return nil
        }
    }
}
