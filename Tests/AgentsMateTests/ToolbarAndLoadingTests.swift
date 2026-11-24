import XCTest
@testable import AgentsMate

final class ToolbarAndLoadingTests: XCTestCase {
    func testASessionBelongsToARepositoryOrItsWorktreesOnly() {
        let repo = "/tmp/example/repo"
        XCTAssertTrue(DiscoveredSession.isInRepository(repo, anyOf: [repo]))
        XCTAssertTrue(DiscoveredSession.isInRepository(repo + "/.worktrees/a", anyOf: [repo]))
        XCTAssertTrue(DiscoveredSession.isInRepository(repo + "/.claude/worktrees/a/src", anyOf: [repo]))
        XCTAssertFalse(DiscoveredSession.isInRepository(repo + "/nested", anyOf: [repo]))
        XCTAssertFalse(DiscoveredSession.isInRepository("/tmp/example/repo-two", anyOf: [repo]))
        XCTAssertFalse(DiscoveredSession.isInRepository(nil, anyOf: [repo]))
    }

    func testProgressCountsAFailedHostAsFinished() {
        let progress = LaneLoadProgress(stages: [nil, .unreachable("a"), .findingSession, .checkingHost("b")])
        XCTAssertEqual(progress, LaneLoadProgress(finished: 2, total: 4))
        XCTAssertEqual(progress.title, "2 of 4 loaded")
        XCTAssertTrue(progress.isLoading)
    }

    func testCountsAreMarkedPartialWhileLoading() {
        let loading = LaneLoadProgress(finished: 1, total: 2)
        XCTAssertEqual(loading.display(0), "–")
        XCTAssertEqual(loading.display(3), "3+")
        XCTAssertEqual(LaneLoadProgress(finished: 2, total: 2).display(0), "0")
    }

    func testTabsCollapseOnlyWhenTheyDoNotFit() {
        let titles = ["Development", "Projects", "Devices", "Reporting"]
        let full = CollapsingTabLayout.fullWidth(titles: titles, selected: "Projects")
        XCTAssertFalse(CollapsingTabLayout.collapses(titles: titles, selected: "Projects", availableWidth: full))
        XCTAssertTrue(CollapsingTabLayout.collapses(titles: titles, selected: "Projects", availableWidth: full - 1))
        XCTAssertLessThan(CollapsingTabLayout.collapsedWidth(titles: titles, selected: "Projects"), full)
    }
}
