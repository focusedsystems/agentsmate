import AgentsMateStatus
import Foundation
import Testing
@testable import AgentsMate

@Suite struct AgentsMateRoutingTests {
    private func opened(_ text: String, installed: Bool) -> [URL] {
        var seen: [URL] = []
        AgentsMateRouting.open(URL(string: text)!, appInstalled: installed) { seen.append($0) }
        return seen
    }

    @Test func aPullLinkOpensInTheAppWhenInstalled() {
        let seen = opened("https://github.com/o/r/pull/12", installed: true)
        #expect(seen.count == 1)
        #expect(seen.first?.scheme == "agentsmate")
        #expect(seen.first.flatMap(AgentsMateLink.parse)?.web.absoluteString == "https://github.com/o/r/pull/12")
    }

    @Test func aLinkOpensAsBeforeWhenTheAppIsNotInstalled() {
        #expect(opened("https://github.com/o/r/pull/12", installed: false).map(\.absoluteString)
                == ["https://github.com/o/r/pull/12"])
        #expect(opened("https://github.com/o/r/commit/abc1234", installed: false).map(\.absoluteString)
                == ["https://github.com/o/r/commit/abc1234"])
    }

    @Test func otherLinksNeverGoToTheApp() {
        #expect(opened("https://example.com/a", installed: true).map(\.absoluteString) == ["https://example.com/a"])
        #expect(opened("https://github.com/o/r/issues/3", installed: true).map(\.absoluteString)
                == ["https://github.com/o/r/issues/3"])
    }

    @Test func theMacIsNotAskedForALinkTheAppCannotTake() {
        var asked = false
        AgentsMateRouting.open(URL(string: "https://example.com")!, appInstalled: { asked = true; return true }()) { _ in }
        #expect(!asked)
    }
}
