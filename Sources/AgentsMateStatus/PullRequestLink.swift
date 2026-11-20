import Foundation

/// Which pull request links AgentsMate will collect from a transcript and
/// open. Transcript text is written by the agent, so a link is opened only
/// when it has exactly the shape of a GitHub or Azure DevOps pull request.
public enum PullRequestLink {
    /// An owner, organisation, collection or host label.
    static let label = "[A-Za-z0-9-]+"
    /// A repository or project name.
    static let name = "[A-Za-z0-9._-]+"

    private static func anchored(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants, so they always compile.
        try! NSRegularExpression(pattern: "^" + pattern + "$")
    }

    private static let githubHost = anchored(#"github\.com"#)
    private static let devOpsHost = anchored(#"dev\.azure\.com"#)
    private static let visualStudioHost = anchored(label + #"\.visualstudio\.com"#)

    private static let githubPath = anchored("/\(label)/\(name)/pull/[0-9]+")
    private static let devOpsPath = anchored("/\(label)/\(name)/_git/\(name)/pullrequest/[0-9]+")
    private static let visualStudioPath = anchored("/(?:\(label)/)?\(name)/_git/\(name)/pullrequest/[0-9]+")

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whether `url` is a pull request link safe to open: `https`, a GitHub
    /// or Azure DevOps host exactly, no user, password, query or fragment,
    /// and a path in the pull request shape.
    public static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil,
              let host = url.host(percentEncoded: true)?.lowercased() else { return false }
        let path = url.path(percentEncoded: true)
        if matches(githubHost, host) { return matches(githubPath, path) }
        if matches(devOpsHost, host) { return matches(devOpsPath, path) }
        if matches(visualStudioHost, host) { return matches(visualStudioPath, path) }
        return false
    }
}
