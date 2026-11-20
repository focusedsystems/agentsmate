import XCTest
@testable import AgentsMateStatus

final class PullRequestLinkTests: XCTestCase {
    private func trusted(_ string: String) -> Bool {
        URL(string: string).map(PullRequestLink.isTrusted) ?? false
    }

    func testAcceptsPullRequestShapes() {
        XCTAssertTrue(trusted("https://github.com/acme/widgets/pull/12"))
        XCTAssertTrue(trusted("https://github.com/acme/my.repo_v-2/pull/1"))
        XCTAssertTrue(trusted("https://org.visualstudio.com/Proj/_git/repo/pullrequest/56"))
        XCTAssertTrue(trusted("https://org.visualstudio.com/Collection/Proj/_git/repo/pullrequest/56"))
    }

    func testRejectsOtherSchemesAndHosts() {
        XCTAssertFalse(trusted("http://github.com/acme/widgets/pull/12"))
        XCTAssertFalse(trusted("javascript://github.com/acme/widgets/pull/12"))
        XCTAssertFalse(trusted("https://github.com.evil.example/acme/widgets/pull/12"))
        XCTAssertFalse(trusted("https://evilgithub.com/acme/widgets/pull/12"))
        XCTAssertFalse(trusted("https://a.b.visualstudio.com/Proj/_git/repo/pullrequest/1"))
        XCTAssertFalse(trusted("https://visualstudio.com.evil.example/Proj/_git/repo/pullrequest/1"))
        XCTAssertFalse(trusted("https://github.com:8443/acme/widgets/pull/12"))
    }

    func testRejectsUserInfoQueryAndFragment() {
        XCTAssertFalse(trusted("https://x@github.com/acme/widgets/pull/12"))
        XCTAssertFalse(trusted("https://x:y@github.com/acme/widgets/pull/12"))
        XCTAssertFalse(trusted("https://github.com/acme/widgets/pull/12?redirect=https://evil.example"))
        XCTAssertFalse(trusted("https://github.com/acme/widgets/pull/12?"))
        XCTAssertFalse(trusted("https://github.com/acme/widgets/pull/12#frag"))
    }

    func testRejectsOtherPaths() {
        XCTAssertFalse(trusted("https://github.com/acme/widgets/issues/3"))
        XCTAssertFalse(trusted("https://github.com/acme/widgets/pull/12/files"))
        XCTAssertFalse(trusted("https://github.com/acme/widgets/pull/abc"))
        XCTAssertFalse(trusted("https://github.com/ac%2Fme/widgets/pull/12"))
        XCTAssertFalse(trusted("https://github.com/acme/../evil/pull/12"))
        XCTAssertFalse(trusted("https://org.visualstudio.com/Proj/_git/repo/pullrequest/x"))
    }

    func testTranscriptKeepsOnlyTrustedLinks() {
        let text = """
        Opened https://github.com/acme/widgets/pull/12 and http://github.com/acme/widgets/pull/13, \
        also https://x@github.com/acme/widgets/pull/14 and https://evilgithub.com/acme/widgets/pull/15.
        """
        XCTAssertEqual(LaneTranscript.pullRequestLinks(in: text).map(\.absoluteString),
                       ["https://github.com/acme/widgets/pull/12"])
    }
}
