import Foundation
import Testing
@testable import AgentsMateStatus

private let azure = ["dev", "azure", "com"].joined(separator: ".")

@Suite struct AgentsMateLinkTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func classifiesGitHubAddresses() {
        #expect(AgentsMateLink.kind(of: url("https://github.com/o/r/pull/12")) == .pull)
        #expect(AgentsMateLink.kind(of: url("https://github.com/o/r/pull/12/files")) == .pull)
        #expect(AgentsMateLink.kind(of: url("https://github.com/o/r/actions/runs/99")) == .pipeline)
        #expect(AgentsMateLink.kind(of: url("https://github.com/o/r/commit/abc1234")) == .commit)
        #expect(AgentsMateLink.kind(of: url("https://github.com/o/r/issues/3")) == nil)
        #expect(AgentsMateLink.kind(of: url("https://github.com/o/r")) == nil)
    }

    @Test func classifiesAzureDevOpsAddresses() {
        #expect(AgentsMateLink.kind(of: url("https://\(azure)/org/Proj/_git/repo/pullrequest/5")) == .pull)
        #expect(AgentsMateLink.kind(of: url("https://\(azure)/org/Proj/_git/repo/commit/0123456789abcdef")) == .commit)
        #expect(AgentsMateLink.kind(of: url("https://\(azure)/org/Proj/_build/results?buildId=7")) == .pipeline)
        #expect(AgentsMateLink.kind(of: url("https://acme.visualstudio.com/Proj/_git/repo/pullrequest/5")) == .pull)
        #expect(AgentsMateLink.kind(of: url("https://\(azure)/org/Proj/_git/repo/pullrequest/5?x=1")) == nil)
    }

    @Test func refusesAnythingElse() {
        #expect(AgentsMateLink.kind(of: url("http://github.com/o/r/pull/1")) == nil)
        #expect(AgentsMateLink.kind(of: url("https://github.com.evil.example/o/r/pull/1")) == nil)
        #expect(AgentsMateLink.kind(of: url("https://user@github.com/o/r/pull/1")) == nil)
        #expect(AgentsMateLink.kind(of: url("https://github.com:8443/o/r/pull/1")) == nil)
        #expect(AgentsMateLink.kind(of: url("https://github.com/o/r/pull/1#x")) == nil)
        #expect(AgentsMateLink.kind(of: url("file:///etc/passwd")) == nil)
    }

    @Test func appLinkRoundTrips() throws {
        let web = url("https://github.com/o/r/pull/12")
        let link = try #require(AgentsMateLink.appURL(for: web))
        #expect(link.scheme == "agentsmate")
        #expect(link.host == "pull")
        let parsed = try #require(AgentsMateLink.parse(link))
        #expect(parsed.kind == .pull)
        #expect(parsed.web == web)

        let build = url("https://\(azure)/org/Proj/_build/results?buildId=7&view=logs")
        let buildLink = try #require(AgentsMateLink.appURL(for: build))
        #expect(AgentsMateLink.parse(buildLink)?.web == build)
    }

    @Test func parseRefusesMismatchedOrUntrustedLinks() {
        #expect(AgentsMateLink.parse(url("agentsmate://commit?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1")) == nil)
        #expect(AgentsMateLink.parse(url("agentsmate://pull?url=https%3A%2F%2Fexample.com%2Fo%2Fr%2Fpull%2F1")) == nil)
        #expect(AgentsMateLink.parse(url("agentsmate://open?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F1")) == nil)
        #expect(AgentsMateLink.parse(url("agentsmate://pull")) == nil)
        #expect(AgentsMateLink.parse(url("https://github.com/o/r/pull/1")) == nil)
    }

    @Test func identifiersNameThePullOrCommit() {
        #expect(AgentsMateLink.identifier(of: url("https://github.com/o/r/pull/12")) == "12")
        #expect(AgentsMateLink.identifier(of: url("https://\(azure)/org/P/_git/r/pullrequest/5")) == "5")
        #expect(AgentsMateLink.identifier(of: url("https://github.com/o/r/commit/ABC1234")) == "abc1234")
        #expect(AgentsMateLink.identifier(of: url("https://github.com/o/r/actions/runs/9")) == nil)
    }

    @Test func routingUsesTheAppOnlyWhenInstalledAndKnown() throws {
        let web = url("https://github.com/o/r/pull/12")
        #expect(AgentsMateLink.destination(for: web, appInstalled: false) == web)
        #expect(AgentsMateLink.destination(for: web, appInstalled: true).scheme == "agentsmate")
        let other = url("https://github.com/o/r/issues/3")
        #expect(AgentsMateLink.destination(for: other, appInstalled: true) == other)
    }
}
