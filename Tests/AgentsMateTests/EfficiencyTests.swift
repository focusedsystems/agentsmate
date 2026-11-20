import XCTest
@testable import AgentsMate

@MainActor
final class EfficiencyTests: XCTestCase {
    // MARK: Cadence

    func testBacksOffWhenInactiveLowPowerOrHot() {
        XCTAssertFalse(BackgroundCadence.backsOff(appActive: true, lowPower: false, thermal: .nominal))
        XCTAssertFalse(BackgroundCadence.backsOff(appActive: true, lowPower: false, thermal: .fair))
        XCTAssertTrue(BackgroundCadence.backsOff(appActive: false, lowPower: false, thermal: .nominal))
        XCTAssertTrue(BackgroundCadence.backsOff(appActive: true, lowPower: true, thermal: .nominal))
        XCTAssertTrue(BackgroundCadence.backsOff(appActive: true, lowPower: false, thermal: .serious))
        XCTAssertTrue(BackgroundCadence.backsOff(appActive: true, lowPower: false, thermal: .critical))
    }

    func testTimerStretchesWhileBackedOffAndKeepsTolerance() {
        let cadence = BackgroundCadence()
        var fired = 0
        let timer = CadenceTimer(interval: 60, cadence: cadence) { fired += 1 }
        defer { timer.invalidate() }
        XCTAssertEqual(timer.currentInterval, 60)
        XCTAssertGreaterThanOrEqual(timer.tolerance, 6)

        cadence.update(appActive: false, lowPower: false, thermal: .nominal)
        XCTAssertEqual(timer.currentInterval, 240)
        XCTAssertGreaterThanOrEqual(timer.tolerance, 24)
        // Not overdue yet: coming back does not fire.
        cadence.update(appActive: true, lowPower: false, thermal: .nominal)
        XCTAssertEqual(timer.currentInterval, 60)
        XCTAssertEqual(fired, 0)
    }

    func testCatchUpFiresOnceWhenOverdue() {
        let cadence = BackgroundCadence()
        var fired = 0
        let timer = CadenceTimer(interval: 0.2, cadence: cadence) { fired += 1 }
        defer { timer.invalidate() }
        cadence.update(appActive: false, lowPower: false, thermal: .nominal)
        // Backed off to 0.8 s; after 0.3 s a tick is overdue at the normal rate.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(fired, 0)
        cadence.update(appActive: true, lowPower: false, thermal: .nominal)
        XCTAssertEqual(fired, 1)
    }

    func testOverdue() {
        XCTAssertTrue(CadenceTimer.isOverdue(elapsed: 600, interval: 600))
        XCTAssertFalse(CadenceTimer.isOverdue(elapsed: 599, interval: 600))
    }

    // MARK: Lane poll

    func testLanePollInterval() {
        XCTAssertNil(AgentLaneSession.pollInterval(attached: false, visible: true, directoryFromShell: false))
        XCTAssertEqual(AgentLaneSession.pollInterval(attached: true, visible: true, directoryFromShell: true), 5)
        XCTAssertEqual(AgentLaneSession.pollInterval(attached: true, visible: false, directoryFromShell: false), 30)
        // Out of sight, and the shell reports its own directory: no timer.
        XCTAssertNil(AgentLaneSession.pollInterval(attached: true, visible: false, directoryFromShell: true))
    }

    // MARK: HEAD files

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eff-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testGitDirFromDotGitFile() {
        let folder = URL(fileURLWithPath: "/work/repo/.worktrees/x")
        XCTAssertEqual(LaneRowMetadataReader.gitDir(fromDotGitFile: "gitdir: /work/repo/.git/worktrees/x\n", in: folder)?.path,
                       "/work/repo/.git/worktrees/x")
        XCTAssertEqual(LaneRowMetadataReader.gitDir(fromDotGitFile: "gitdir: ../../.git/worktrees/x", in: folder)?.path,
                       "/work/repo/.git/worktrees/x")
        XCTAssertNil(LaneRowMetadataReader.gitDir(fromDotGitFile: "nonsense", in: folder))
        XCTAssertNil(LaneRowMetadataReader.gitDir(fromDotGitFile: "gitdir:   ", in: folder))
        XCTAssertNil(LaneRowMetadataReader.gitDir(fromDotGitFile: nil, in: folder))
    }

    func testHeadFileForRepositoryAndWorktree() throws {
        let root = try makeRoot()
        let git = root.appendingPathComponent("repo/.git")
        let worktreeGit = git.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature\n".write(to: worktreeGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("repo/.worktrees/feature")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "gitdir: ../../.git/worktrees/feature\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(LaneRowMetadataReader.headFile(for: root.appendingPathComponent("repo").path)?.path,
                       git.appendingPathComponent("HEAD").path)
        let head = LaneRowMetadataReader.headFile(for: worktree.appendingPathComponent("src").path)
        XCTAssertEqual(head?.path, worktreeGit.appendingPathComponent("HEAD").path)
        XCTAssertEqual(head.flatMap(LaneRowMetadataReader.branch(headFile:)), "feature")
        XCTAssertNil(LaneRowMetadataReader.headFile(for: root.path))
    }

    func testHeadWatcherSeesBranchSwitchesByRename() throws {
        let root = try makeRoot()
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let head = git.appendingPathComponent("HEAD")
        try "ref: refs/heads/main\n".write(to: head, atomically: true, encoding: .utf8)

        var seen: [String?] = []
        let watchers = HeadWatchers { url in seen.append(LaneRowMetadataReader.branch(headFile: url)) }
        watchers.watch(["a": head, "b": head])
        XCTAssertEqual(watchers.watchedFiles, [head])
        XCTAssertEqual(watchers.lanes(watching: head), ["a", "b"])

        // Git writes HEAD.lock and renames it over HEAD; the watcher must
        // follow the new file each time.
        for branch in ["one", "two"] {
            let lock = git.appendingPathComponent("HEAD.lock")
            try "ref: refs/heads/\(branch)\n".write(to: lock, atomically: false, encoding: .utf8)
            XCTAssertEqual(rename(lock.path, head.path), 0)
            let deadline = Date().addingTimeInterval(2)
            while seen.last != branch, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            XCTAssertEqual(seen.last, branch)
        }

        watchers.watch([:])
        XCTAssertTrue(watchers.watchedFiles.isEmpty)
    }

    // MARK: Sweeps

    func testPullRequestCache() {
        let now = Date()
        typealias C = RowMetadataSchedule.CachedPullRequest
        let open = LaneRowMetadata.PullRequest(number: 1, state: .open, url: nil)
        XCTAssertTrue(RowMetadataSchedule.needsFetch(nil, now: now))
        XCTAssertFalse(RowMetadataSchedule.needsFetch(C(date: now.addingTimeInterval(-299), value: open), now: now))
        XCTAssertTrue(RowMetadataSchedule.needsFetch(C(date: now.addingTimeInterval(-300), value: open), now: now))
        XCTAssertTrue(RowMetadataSchedule.needsFetch(C(date: now.addingTimeInterval(-300), value: nil), now: now))
        for state in [LaneRowMetadata.PullRequest.State.merged, .closed] {
            let final = LaneRowMetadata.PullRequest(number: 2, state: state, url: nil)
            XCTAssertFalse(RowMetadataSchedule.needsFetch(C(date: now.addingTimeInterval(-86_400), value: final), now: now))
        }
    }

    func testSweepsSkipWhileRunningAndQueueLanes() {
        var sweeps = RowMetadataSweeps()
        XCTAssertTrue(sweeps.begin(.all, lanes: ["a", "b"]))
        XCTAssertFalse(sweeps.begin(.all, lanes: ["a", "b"]))
        XCTAssertTrue(sweeps.begin(.lanes, lanes: ["a"]))
        XCTAssertFalse(sweeps.begin(.lanes, lanes: ["b"]))
        XCTAssertFalse(sweeps.begin(.lanes, lanes: ["b", "c"]))
        XCTAssertEqual(sweeps.end(.all), [])
        XCTAssertEqual(sweeps.end(.lanes), ["b", "c"])
        XCTAssertTrue(sweeps.running.isEmpty)
        XCTAssertEqual(sweeps.end(.lanes), [])
    }

    func testIntervals() {
        XCTAssertEqual(RowMetadataSchedule.fullSweep, 600)
        XCTAssertEqual(RowMetadataSchedule.visibleSweep, 60)
        XCTAssertGreaterThanOrEqual(CadenceTimer.toleranceFraction, 0.1)
    }
}
