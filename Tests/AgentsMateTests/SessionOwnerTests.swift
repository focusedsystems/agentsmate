import XCTest
@testable import AgentsMate
import AgentsMateStatus

@MainActor
final class SessionOwnerTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("owner-\(UUID().uuidString)", isDirectory: true)
        file = folder.appendingPathComponent("agentsmate/session-owner.json")
        let url = folder
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    }

    private func lane(_ id: String, session: String? = "sess-1") -> AgentLane {
        var lane = AgentLane(id: id, title: id, directory: URL(fileURLWithPath: "/work/repo"), backendID: "agent")
        lane.agentSessionID = session
        return lane
    }

    private func store(_ app: String, shared: (@Sendable (AgentLane) -> Bool)? = { _ in true }, lanes: [AgentLane]? = nil) -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil, sessionOwnerFile: file, ownerAppID: app,
                                                  isLaneShared: shared)
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend.tmuxLane(id: "agent", displayName: "Agent", command: "true",
                                                                          statusAgent: "claude", tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"]))],
                                   statusFeed: nil, defaults: UserDefaults(suiteName: "agentsmate-owner-\(UUID().uuidString)")!)
        store.sync(lanes: lanes ?? [lane("one")])
        // Every app these tests name counts as running, unless a test says otherwise.
        store.ownership?.isRunning = { _ in true }
        return store
    }

    private func notifies(_ store: AgentLaneStore, _ id: String = "one") -> Bool { store.shouldNotify(for: store.sessions[id]!) }

    func testOnlyTheAppTheSessionWasWorkedInNotifiesAndTheHandoffMovesIt() {
        let a = store("app.a"), b = store("app.b")
        a.open("one")
        a.ownership?.flush()
        XCTAssertTrue(notifies(a))
        XCTAssertFalse(notifies(b))
        b.open("one")
        b.ownership?.flush()
        XCTAssertFalse(notifies(a), "the previous owner goes quiet")
        XCTAssertTrue(notifies(b))
    }

    func testTheBadgeLeavesOutASessionAnotherAppOwns() {
        let a = store("app.a"), b = store("app.b")
        a.open("one")
        a.ownership?.flush()
        a.ownership?.reload()
        b.ownership?.reload()
        let expectation = expectation(description: "reloaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(a.ownsSession(a.sessions["one"]!))
        XCTAssertFalse(b.ownsSession(b.sessions["one"]!))
    }

    func testSendingAndDuplicatingClaimToo() {
        let a = store("app.a"), b = store("app.b")
        a.open("one")
        a.ownership?.flush()
        b.ownership?.reload()
        b.ownership?.flush()
        _ = b.send("hi", to: "one")
        XCTAssertTrue(notifies(a), "the message was copied, not sent: nothing was worked in")
        let copy = b.duplicate("one")
        b.ownership?.flush()
        XCTAssertNotNil(copy)
        XCTAssertTrue(b.shouldNotify(for: copy!))
    }

    func testAClosedOwnerHandsTheSessionToTheAppThatIsRunning() {
        let a = store("app.a"), b = store("app.b")
        a.open("one")
        a.ownership?.flush()
        b.ownership?.isRunning = { _ in false }
        XCTAssertTrue(notifies(a), "the owner is running and owns it")
        XCTAssertTrue(notifies(b), "app.a is closed, so app.b speaks for it")
        a.ownership?.isRunning = { _ in false }
        b.ownership?.isRunning = { $0 == "app.a" }
        XCTAssertTrue(notifies(a))
        XCTAssertFalse(notifies(b), "the owner is running again")
    }

    func testAnUnsharedLaneIsAlwaysOwned() {
        let a = store("app.a", shared: { _ in false }), b = store("app.b", shared: { _ in false })
        a.open("one")
        a.ownership?.flush()
        XCTAssertTrue(notifies(a))
        XCTAssertTrue(notifies(b), "unshared in this app: its behaviour is unchanged")
        let c = store("app.c", shared: nil)
        XCTAssertTrue(notifies(c), "an app with no sharing data notifies as before")
    }

    func testWithoutAFileTheGateIsOff() {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, displayedExportFile: nil, sessionOwnerFile: nil)
        let store = AgentLaneStore(configuration: config, backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-owner-\(UUID().uuidString)")!)
        store.sync(lanes: [lane("one")])
        XCTAssertTrue(store.shouldNotify(for: store.sessions["one"]!))
    }

    func testTheCreatorOwnsWhenNobodyHasWorkedInItSince() {
        let a = store("app.a"), b = store("app.b")
        let copy = a.duplicate("one")
        a.ownership?.flush()
        XCTAssertNotNil(copy)
        let later = Date().addingTimeInterval(SessionOwners.ownerMaxAge + 3600)
        let keys = a.ownership!.keys(for: copy!)
        let snapshot = SessionOwners.load(file, now: later)
        XCTAssertNil(snapshot.owner(for: keys, now: later))
        XCTAssertEqual(snapshot.creator(for: keys), "app.a")
        _ = b
    }

    func testTheExportNamesTheOwner() {
        let a = store("app.a"), b = store("app.b")
        a.open("one")
        a.ownership?.flush()
        b.ownership?.reload()
        let expectation = expectation(description: "reloaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(a.displayedExport().rows.first?.ownerApp, "app.a")
        XCTAssertEqual(b.displayedExport().rows.first?.ownerApp, "app.a")
    }

    func testAClaimFromARestoredLaunchAttachIsNotOne() {
        let a = store("app.a")
        a.suppressOwnerClaim = true
        a.open("one")
        a.suppressOwnerClaim = false
        a.ownership?.flush()
        XCTAssertEqual(SessionOwners.load(file).entries, [:])
    }

    func testABadFileMeansNoOneHasClaimedAndASharedLaneFallsBack() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: file)
        chmod(file.path, 0o666)
        let a = store("app.a")
        XCTAssertEqual(a.ownership?.snapshot.entries, [:])
        a.open("one")
        a.ownership?.flush()
        XCTAssertEqual(SessionOwners.load(file).entries.isEmpty, false, "the next claim replaces the bad file")
        XCTAssertTrue(notifies(a))
    }

    private func finder(_ app: String) -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: true,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil, sessionOwnerFile: file, ownerAppID: app)
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend.tmuxLane(id: "agent", displayName: "Agent", command: "true",
                                                                          statusAgent: "claude", tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"]))],
                                   statusFeed: nil, defaults: UserDefaults(suiteName: "agentsmate-owner-\(UUID().uuidString)")!)
        store.ownership?.isRunning = { _ in true }
        store.received(found: [.init(backendID: "agent", session: DiscoveredSession(kind: "tmux", name: "lane-x", directory: "/work/repo",
                                                                                     agentID: "sess-1"))])
        return store
    }

    func testAnAppNeverOwnsASessionItOnlyFoundRunning() throws {
        SessionOwners.claim(.init(sessionIDs: ["sess-1"], tmuxName: "lane-x"), app: "app.b", in: file)
        // A claim this app made before it stopped listing the session, newer than b's.
        let stale = Date().addingTimeInterval(60)
        SessionOwners.claim(.init(sessionIDs: ["sess-1"]), app: "app.a", at: stale, in: file)
        let a = finder("app.a")
        let id = try XCTUnwrap(a.detachedIDs.first)
        let row = try XCTUnwrap(a.sessions[id])
        XCTAssertEqual(a.ownerApp(of: row), "app.b", "its own old claim is ignored")
        XCTAssertFalse(a.shouldNotify(for: row))
        a.claimOwnership(of: row)
        a.open(id)
        a.ownership?.flush()
        XCTAssertEqual(SessionOwners.load(file).entries["sess-1"]?.app, "app.a", "a found row claims nothing new")
        XCTAssertEqual(SessionOwners.load(file).entries["sess-1"]?.at.timeIntervalSince1970 ?? 0, stale.timeIntervalSince1970, accuracy: 1)
    }

    func testAFoundSessionNobodyElseListsStillHasAnAnswerer() throws {
        let a = finder("app.a")
        let row = try XCTUnwrap(a.sessions[try XCTUnwrap(a.detachedIDs.first)])
        XCTAssertEqual(a.ownerApp(of: row), "app.a")
    }

    func testSharingStartsAtLaunchWithoutAnyRestore() throws {
        let previous = AgentLaneStore.sharedLanesStartDelay
        AgentLaneStore.sharedLanesStartDelay = 0.05
        defer { AgentLaneStore.sharedLanesStartDelay = previous }
        let hosts = AgentHosts(hosts: [.init(name: "hub-mac", role: .hub)], selfName: "hub-mac")
        let transport = LaunchTransport()
        let settings = SharedLaneSettings(appID: "example.app",
                                          cacheFile: FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).json"),
                                          restores: false, transport: transport, hosts: hosts)
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                        sharedLanes: settings),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-owner-\(UUID().uuidString)")!)
        store.sync(lanes: [lane("one")])
        let started = expectation(description: "started")
        Task { @MainActor in
            while store.sharedLanes?.appliedOnce != true { try? await Task.sleep(nanoseconds: 50_000_000) }
            started.fulfill()
        }
        wait(for: [started], timeout: 10)
        XCTAssertGreaterThan(transport.reads, 0, "it read the hub with no restore and no activation")
    }
}

private final class LaunchTransport: SharedLaneTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var count = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; count += 1; return data }
    func write(_ data: Data) throws { lock.lock(); self.data = data; lock.unlock() }
}
