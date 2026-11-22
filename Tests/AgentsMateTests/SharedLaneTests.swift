import XCTest
@testable import AgentsMate

private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

private func lane(_ id: String, title: String? = nil, variant: String? = nil, order: Int = 0,
                  updated: TimeInterval) -> SharedLaneList.Lane {
    SharedLaneList.Lane(id: id, title: title, directory: "~/work", backendID: "w", command: "lane-wrapper",
                        variantFlag: "-n", variant: variant, order: order, updated: date(updated))
}

final class SharedLaneListTests: XCTestCase {
    func testMergeKeepsTheNewestCopyOfEachLane() {
        let a = SharedLaneList(lanes: [lane("1", title: "old", updated: 10), lane("2", order: 1, updated: 10)])
        let b = SharedLaneList(lanes: [lane("1", title: "new", updated: 20), lane("3", order: 2, updated: 5)])
        let merged = SharedLaneList.merge([a, b], now: date(100))
        XCTAssertEqual(merged.lanes.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(merged.lane("1")?.title, "new")
        XCTAssertEqual(SharedLaneList.merge([b, a], now: date(100)).lane("1")?.title, "new", "order of copies does not matter")
    }

    func testMergeSortsByOrder() {
        let merged = SharedLaneList.merge([SharedLaneList(lanes: [lane("b", order: 2, updated: 1), lane("a", order: 1, updated: 1)])],
                                          now: date(100))
        XCTAssertEqual(merged.lanes.map(\.id), ["a", "b"])
    }

    func testCloseNewerThanTheLaneKeepsItClosed() {
        let open = SharedLaneList(lanes: [lane("1", updated: 10)])
        let closed = SharedLaneList(closed: [.init(id: "1", at: date(20))])
        let merged = SharedLaneList.merge([closed, open], now: date(100))
        XCTAssertTrue(merged.lanes.isEmpty)
        XCTAssertEqual(merged.closed, [.init(id: "1", at: date(20))])
        XCTAssertTrue(SharedLaneList.merge([open, closed], now: date(100)).lanes.isEmpty)
    }

    func testCloseAtTheSameSecondWins() {
        let merged = SharedLaneList.merge([SharedLaneList(lanes: [lane("1", updated: 20)], closed: [.init(id: "1", at: date(20))])],
                                          now: date(100))
        XCTAssertTrue(merged.lanes.isEmpty)
    }

    func testLaneChangedAfterItsCloseComesBackAndTheCloseGoes() {
        let merged = SharedLaneList.merge([SharedLaneList(closed: [.init(id: "1", at: date(20))]),
                                           SharedLaneList(lanes: [lane("1", updated: 30)])], now: date(100))
        XCTAssertEqual(merged.lanes.map(\.id), ["1"])
        XCTAssertTrue(merged.closed.isEmpty)
    }

    func testClosesOlderThanAWeekAreDropped() {
        let now = date(SharedLaneList.tombstoneLifetime + 1000)
        let merged = SharedLaneList.merge([SharedLaneList(closed: [.init(id: "old", at: date(0)), .init(id: "new", at: date(999 + SharedLaneList.tombstoneLifetime))])],
                                          now: now)
        XCTAssertEqual(merged.closed.map(\.id), ["new"])
    }

    func testAStaleMacCannotBringBackALaneClosedElsewhere() {
        // This Mac last synced the lane at 10; another Mac closed it at 20.
        let base = SharedLaneList(lanes: [lane("1", updated: 10)])
        let remote = SharedLaneList(closed: [.init(id: "1", at: date(20))])
        var mine = lane("1", updated: 0)
        mine.updated = .distantPast
        let merged = SharedLaneList.reconcile(local: [mine], base: base, remote: remote, closing: [], now: date(30))
        XCTAssertTrue(merged.lanes.isEmpty)
        XCTAssertEqual(merged.closed.map(\.id), ["1"])
    }

    func testReconcileStampsOnlyWhatChangedHere() {
        let base = SharedLaneList(lanes: [lane("1", title: "A", updated: 10), lane("2", title: "B", order: 1, updated: 10)])
        let remote = base
        let local = [lane("1", title: "A", updated: 0), lane("2", title: "B2", order: 1, updated: 0), lane("3", order: 2, updated: 0)]
        let merged = SharedLaneList.reconcile(local: local, base: base, remote: remote, closing: [.init(id: "4", at: date(40))],
                                              now: date(50))
        XCTAssertEqual(merged.lane("1")?.updated, date(10), "unchanged keeps its time")
        XCTAssertEqual(merged.lane("2")?.updated, date(50))
        XCTAssertEqual(merged.lane("2")?.title, "B2")
        XCTAssertEqual(merged.lane("3")?.updated, date(50), "new here")
        XCTAssertEqual(merged.closed.map(\.id), ["4"])
    }

    func testReconcileTakesARemoteChangeToALaneUnchangedHere() {
        let base = SharedLaneList(lanes: [lane("1", title: "A", updated: 10)])
        let remote = SharedLaneList(lanes: [lane("1", title: "Renamed", updated: 20)])
        let merged = SharedLaneList.reconcile(local: [lane("1", title: "A", updated: 0)], base: base, remote: remote, closing: [],
                                              now: date(30))
        XCTAssertEqual(merged.lane("1")?.title, "Renamed")
        XCTAssertEqual(merged, remote, "nothing to write back")
    }

    func testFileUsesTheContractFieldNamesWithNulls() throws {
        let list = SharedLaneList(lanes: [SharedLaneList.Lane(id: "u1", backendID: "claude", order: 3, updated: date(0))],
                                  closed: [.init(id: "u2", at: date(60))])
        let object = try JSONSerialization.jsonObject(with: list.encoded()) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 1)
        let first = (object?["lanes"] as? [[String: Any]])?.first
        XCTAssertEqual(Set(first?.keys.map { $0 } ?? []),
                       ["id", "title", "directory", "backendID", "command", "variantFlag", "variant", "host",
                        "section", "pinned", "order", "updated"])
        XCTAssertTrue(first?["variant"] is NSNull)
        XCTAssertEqual(first?["updated"] as? String, "2027-01-15T08:00:00Z")
        let closed = (object?["closed"] as? [[String: Any]])?.first
        XCTAssertEqual(closed?["at"] as? String, "2027-01-15T08:01:00Z")
        XCTAssertEqual(try SharedLaneList.decode(list.encoded()), list)
    }

    func testDecodingSkipsBadLanesAndReadsFractionalTimes() throws {
        let json = """
        {"version":1,"lanes":[{"id":"a","backendID":"claude","updated":"2026-11-21T17:30:00.250Z"},
         {"title":"no id"}],"closed":[{"id":"z","at":"2026-11-21T17:31:00Z"}]}
        """
        let list = try SharedLaneList.decode(Data(json.utf8))
        XCTAssertEqual(list.lanes.map(\.id), ["a"])
        XCTAssertEqual(list.lanes[0].updated, try SharedLaneDate.decode("2026-11-21T17:30:00Z"))
        XCTAssertEqual(list.closed.map(\.id), ["z"])
    }

    func testTildePaths() {
        XCTAssertEqual(SharedLaneList.tildePath("/Users/me/work/a", home: "/Users/me"), "~/work/a")
        XCTAssertEqual(SharedLaneList.tildePath("/Users/me", home: "/Users/me/"), "~")
        XCTAssertEqual(SharedLaneList.tildePath("/Users/meow/a", home: "/Users/me"), "/Users/meow/a")
        XCTAssertEqual(SharedLaneList.tildePath("/opt/x", home: "/Users/me"), "/opt/x")
    }

    func testLocalTransportWritesAtomically() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = LocalSharedLaneTransport(appID: "example.app", home: folder)
        XCTAssertNil(try transport.read())
        try transport.write(Data("{}".utf8))
        XCTAssertEqual(try transport.read(), Data("{}".utf8))
        XCTAssertEqual(transport.file.path, folder.appendingPathComponent(".local/state/agentsmate/example.app/lanes.json").path)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: transport.file.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["lanes.json"])
    }

    func testSSHTransportCommands() {
        let ssh = SSHSharedLaneTransport(hub: "hub-mac", appID: "example.app")
        XCTAssertEqual(ssh.arguments("x"), ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "hub-mac", "x"])
        XCTAssertEqual(ssh.readCommand,
                       "if [ -f ~/.local/state/agentsmate/example.app/lanes.json ]; then cat ~/.local/state/agentsmate/example.app/lanes.json; fi")
        XCTAssertEqual(ssh.writeCommand,
                       "mkdir -p ~/.local/state/agentsmate/example.app && cat > ~/.local/state/agentsmate/example.app/lanes.json.tmp.$$ && mv ~/.local/state/agentsmate/example.app/lanes.json.tmp.$$ ~/.local/state/agentsmate/example.app/lanes.json")
        XCTAssertFalse(SharedLanePaths.isValidAppID("a b"))
        XCTAssertFalse(SharedLanePaths.isValidAppID("../x"))
    }
}

final class AgentHostsTests: XCTestCase {
    func testParse() {
        let hosts = AgentHosts.parse("""
        # name     role    platform
        hub-mac    hub     mac
        laptop     client  mac   # comment
        mini-1     lane    mac
        win-1      lane    windows
        bad        nothing
        -x         lane
        """)
        XCTAssertEqual(hosts.map(\.name), ["hub-mac", "laptop", "mini-1", "win-1"])
        XCTAssertEqual(hosts[1].role, .client)
        XCTAssertEqual(hosts[3].platform, "windows")
        let registry = AgentHosts(hosts: hosts, selfName: "laptop")
        XCTAssertEqual(registry.hub?.name, "hub-mac")
        XCTAssertFalse(registry.isHub)
        XCTAssertEqual(registry.laneHosts.map(\.name), ["hub-mac", "mini-1", "win-1"])
    }

    func testLoadNeedsBothFilesAndAHub() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(AgentHosts.load(from: folder))
        try "hub-mac hub mac\n".write(to: folder.appendingPathComponent("hosts.conf"), atomically: true, encoding: .utf8)
        XCTAssertNil(AgentHosts.load(from: folder), "no self file")
        try "hub-mac\n".write(to: folder.appendingPathComponent("self"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentHosts.load(from: folder)?.isHub, true)
        try "laptop client mac\n".write(to: folder.appendingPathComponent("hosts.conf"), atomically: true, encoding: .utf8)
        XCTAssertNil(AgentHosts.load(from: folder), "no hub")
    }

    func testSettingsPickTheTransport() {
        let hosts = [AgentHosts.Host(name: "hub-mac", role: .hub), AgentHosts.Host(name: "mini-1", role: .lane)]
        let onHub = SharedLaneSettings(appID: "example.app", hosts: AgentHosts(hosts: hosts, selfName: "hub-mac")).resolve()
        XCTAssertTrue(onHub?.transport is LocalSharedLaneTransport)
        let elsewhere = SharedLaneSettings(appID: "example.app", hosts: AgentHosts(hosts: hosts, selfName: "mini-1")).resolve()
        XCTAssertEqual((elsewhere?.transport as? SSHSharedLaneTransport)?.hub, "hub-mac")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")
        XCTAssertNil(SharedLaneSettings(appID: "example.app", hostsDirectory: missing).resolve())
    }

    func testTestRunnerIsNotAnAppSoSharingIsOff() {
        XCTAssertNil(SharedLaneSettings.automatic())
    }

    func testHostEnvironment() {
        var lane = AgentLane(id: "a", title: "A", backendID: "w")
        XCTAssertEqual(AgentLaneSession.hostEnvironment(for: lane), [:])
        lane.host = "mini-1"
        XCTAssertEqual(AgentLaneSession.hostEnvironment(for: lane),
                       ["CLAUDE_REMOTE_HOST": "mini-1", "CODEX_REMOTE_HOST": "mini-1"])
    }
}

/// A hub file in memory, shared by every store in a test.
private final class MemoryTransport: SharedLaneTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var failing = false
    private(set) var writes = 0

    func read() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failing { throw CocoaError(.fileReadUnknown) }
        return data
    }

    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw CocoaError(.fileWriteUnknown) }
        self.data = data
        writes += 1
    }

    var list: SharedLaneList? {
        lock.lock(); defer { lock.unlock() }
        return try? data.map(SharedLaneList.decode)
    }
}

private final class StopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class SharedLaneStoreTests: XCTestCase {
    private let stops = StopRecorder()

    private var wrapper: CommandLaneBackend {
        let stops = self.stops
        return CommandLaneBackend.tmuxLane(id: "w", displayName: "W", command: "lane-wrapper", statusAgent: "claude",
                                           stopCommand: { _ in stops.record(); return ["true"] }, variantFlag: "-n")
    }

    private func makeStore(workspaceFile: URL? = nil, sharing transport: MemoryTransport? = nil, me: String = "hub-mac",
                           cache: URL? = nil) -> AgentLaneStore {
        let hosts = AgentHosts(hosts: [.init(name: "hub-mac", role: .hub), .init(name: "mini-1", role: .lane),
                                       .init(name: "laptop", role: .client)], selfName: me)
        let settings = transport.map {
            SharedLaneSettings(appID: "example.app",
                               cacheFile: cache ?? FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString).json"),
                               transport: $0, hosts: hosts)
        }
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, workspaceFile: workspaceFile,
                                                  findsDetachedSessions: false, sharedLanes: settings)
        return AgentLaneStore(configuration: config, backends: [wrapper], statusFeed: nil,
                              defaults: UserDefaults(suiteName: "agentsmate-shared-\(UUID().uuidString)")!)
    }

    private func sync(_ store: AgentLaneStore) {
        let done = expectation(description: "sync")
        store.sharedLanes?.sync { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func folderLane(_ id: String) -> AgentLane {
        AgentLane(id: id, title: "Work", directory: URL(fileURLWithPath: "/tmp/shared-work"), backendID: "w", isClosable: true)
    }

    func testTwoVariantsInOneFolderSurviveSnapshotSaveAndRestore() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = makeStore(workspaceFile: file)
        store.add(folderLane("main"), open: false)
        let copy = try XCTUnwrap(store.duplicate("main", focus: false))
        XCTAssertEqual(copy.lane.variant, "2")
        store.detach(copy.id)

        let snapshot = store.snapshot(named: "Day")
        XCTAssertEqual(snapshot.lanes.map(\.id), ["main", copy.id])
        XCTAssertEqual(snapshot.lanes.map(\.variant), [nil, "2"])
        XCTAssertEqual(snapshot.lanes.map(\.command), ["lane-wrapper", "lane-wrapper"])
        XCTAssertEqual(snapshot.lanes.map(\.variantFlag), ["-n", "-n"])
        store.saveWorkspace(named: "Day")

        var saved = try LaneWorkspaceFile.load(file)
        saved.restore = saved.workspaces.first
        try saved.save(file)

        let restored = makeStore(workspaceFile: file)
        XCTAssertTrue(restored.restoreAtLaunch())
        XCTAssertEqual(restored.lanes.map(\.id), ["main", copy.id], "both lanes, under their own ids")
        XCTAssertEqual(restored.lanes.map(\.variant), [nil, "2"])
        restored.open(workspace: saved.workspaces[0])
        XCTAssertEqual(restored.lanes.count, 2, "opening again adds nothing")
    }

    func testRestoredLanesKeepTheirIDAndHost() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var workspace = LaneWorkspaceFile()
        workspace.restore = LaneWorkspace(name: "Last Session", lanes: [
            .init(directory: "/tmp/shared-work", backendID: "w", id: "lane-1", host: "mini-1"),
        ])
        try workspace.save(file)
        for _ in 0..<2 {
            let store = makeStore(workspaceFile: file)
            store.restoreAtLaunch()
            XCTAssertEqual(store.lanes.map(\.id), ["lane-1"], "the same $AGENTSMATE_LANE every launch")
            XCTAssertEqual(store.lanes.first?.host, "mini-1")
        }
    }

    func testOldFilesWithoutIDsStillRestore() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"workspaces":[],"restore":{"name":"Last Session","sections":[],"lanes":[{"backendID":"w","directory":"/tmp/shared-work"}]}}"#.utf8)
            .write(to: file)
        let store = makeStore(workspaceFile: file)
        XCTAssertTrue(store.restoreAtLaunch())
        XCTAssertEqual(store.lanes.count, 1)
        store.open(workspace: store.workspaces.restore!)
        XCTAssertEqual(store.lanes.count, 1, "an id-less lane is still matched by folder")
    }

    func testNoRegistryMeansNoSharing() {
        let store = makeStore()
        XCTAssertNil(store.sharedLanes)
        XCTAssertNil(store.agentHosts)
        store.add(folderLane("a"), open: false)
        XCTAssertTrue(store.runOnHosts(for: "a").isEmpty)
    }

    func testLanesTravelBetweenMacs() throws {
        let hub = MemoryTransport()
        let first = makeStore(sharing: hub)
        first.add(folderLane("main"), open: false)
        let copy = try XCTUnwrap(first.duplicate("main", focus: false))
        first.detach(copy.id)
        first.setHost(copy.id, to: "mini-1")
        first.rename("main", to: "Main lane")
        sync(first)
        XCTAssertEqual(hub.list?.lanes.map(\.id), ["main", copy.id])
        XCTAssertEqual(hub.list?.lane(copy.id)?.variant, "2")
        XCTAssertEqual(hub.list?.lane(copy.id)?.host, "mini-1")
        XCTAssertEqual(hub.list?.lane("main")?.directory, "/tmp/shared-work")

        let second = makeStore(sharing: hub, me: "laptop")
        sync(second)
        XCTAssertEqual(second.lanes.map(\.id), ["main", copy.id])
        XCTAssertEqual(second.lanes.map(\.variant), [nil, "2"])
        XCTAssertEqual(second.lanes.last?.host, "mini-1")
        XCTAssertEqual(second.sessions["main"]?.title, "Main lane")
        let writes = hub.writes
        sync(second)
        XCTAssertEqual(hub.writes, writes, "a sync that changes nothing writes nothing")

        // Closed on the second Mac: gone from the first one's sidebar, session left running.
        second.close(copy.id)
        second.rename("main", to: "Renamed")
        sync(second)
        XCTAssertEqual(hub.list?.closed.map(\.id), [copy.id])
        sync(first)
        XCTAssertEqual(first.lanes.map(\.id), ["main"])
        XCTAssertEqual(first.sessions["main"]?.title, "Renamed")
        XCTAssertEqual(stops.stops, 0, "closing elsewhere never stops a session")
    }

    func testUnreachableHubFallsBackToTheCache() {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let hub = MemoryTransport()
        let first = makeStore(sharing: hub, cache: cache)
        first.add(folderLane("main"), open: false)
        sync(first)
        first.sharedLanes?.flush()

        hub.failing = true
        let later = makeStore(sharing: hub, cache: cache)
        sync(later)
        XCTAssertNotNil(later.sharedLanes?.lastError)
        XCTAssertEqual(later.lanes.map(\.id), ["main"])
    }

    func testRunOnSetsTheHostAndTheHubIsNoHost() {
        let store = makeStore(sharing: MemoryTransport())
        store.add(folderLane("a"), open: false)
        XCTAssertEqual(store.runOnHosts(for: "a").map(\.name), ["hub-mac", "mini-1"])
        XCTAssertEqual(store.host(of: "a"), "hub-mac")
        store.setHost("a", to: "mini-1")
        XCTAssertEqual(store.lanes.first?.host, "mini-1")
        XCTAssertEqual(store.sessions["a"]?.lane.host, "mini-1")
        store.setHost("a", to: "hub-mac")
        XCTAssertNil(store.lanes.first?.host)
    }
}
