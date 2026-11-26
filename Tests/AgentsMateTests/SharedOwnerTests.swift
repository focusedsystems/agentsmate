import XCTest
@testable import AgentsMate
import AgentsMateStatus

/// The hub's shared claims file, in memory.
private class HubFile: SharedLaneTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var raw: Data? {
        get { lock.lock(); defer { lock.unlock() }; return data }
        set { lock.lock(); data = newValue; lock.unlock() }
    }
    func read() throws -> Data? { raw }
    func write(_ data: Data) throws { raw = data }
}

private final class DownHub: HubFile, @unchecked Sendable {
    override func read() throws -> Data? { throw CocoaError(.fileReadUnknown) }
    override func write(_ data: Data) throws { throw CocoaError(.fileWriteUnknown) }
}

@MainActor
final class SharedOwnerTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared-owner-\(UUID().uuidString)", isDirectory: true)
        let url = folder!
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    }

    private func lane() -> AgentLane {
        var lane = AgentLane(id: "one", title: "one", directory: URL(fileURLWithPath: "/work/repo"), backendID: "agent")
        lane.agentSessionID = "sess-1"
        return lane
    }

    /// One Mac: its own claims file, the hosts registry naming it, and the hub's shared file.
    private func mac(_ host: String, app: String = "app.a", hub: HubFile) -> AgentLaneStore {
        let hosts = AgentHosts(hosts: [.init(name: "hub-mac", role: .hub), .init(name: "laptop", role: .client)], selfName: host)
        let settings = SharedLaneSettings(appID: "example.app",
                                          cacheFile: folder.appendingPathComponent("\(host)-cache.json"),
                                          transport: HubFile(), hosts: hosts, ownerTransport: hub)
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: settings, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil,
                                                  sessionOwnerFile: folder.appendingPathComponent("\(host)/agentsmate/session-owner.json"),
                                                  ownerAppID: app, isLaneShared: { _ in true })
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend.tmuxLane(id: "agent", displayName: "Agent", command: "true",
                                                                          statusAgent: "claude", tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"]))],
                                   statusFeed: nil, defaults: UserDefaults(suiteName: "agentsmate-shared-owner-\(UUID().uuidString)")!)
        store.sync(lanes: [lane()])
        store.ownership?.isRunning = { _ in true }
        return store
    }

    private func syncShared(_ stores: AgentLaneStore..., now: Date = Date()) {
        for store in stores { store.ownership?.syncShared(wait: true, now: now) }
    }

    private func owns(_ store: AgentLaneStore, now: Date = Date()) -> Bool {
        store.ownership!.owns(store.sessions["one"]!, fresh: true, now: now)
    }

    func testWorkingOnOneMacKeepsTheSameAppOnTheOtherSilent() {
        let hub = HubFile()
        let a = mac("hub-mac", hub: hub), b = mac("laptop", hub: hub)
        a.open("one")
        a.ownership?.flush()
        syncShared(a, b, a)
        XCTAssertTrue(owns(a))
        XCTAssertFalse(owns(b), "the claim came from the other Mac, though the bundle id is the same")
        XCTAssertFalse(b.shouldNotify(for: b.sessions["one"]!))
    }

    func testWorkingOnTheOtherMacMovesIt() {
        let hub = HubFile()
        let a = mac("hub-mac", hub: hub), b = mac("laptop", hub: hub)
        a.open("one")
        a.ownership?.flush()
        syncShared(a, b)
        b.open("one")
        b.ownership?.flush()
        syncShared(b, a)
        XCTAssertTrue(owns(b))
        XCTAssertFalse(owns(a), "the newer claim wins on every Mac")
    }

    func testAMacNotHeardFromForTenMinutesNoLongerSpeaksForTheSession() {
        let hub = HubFile()
        let a = mac("hub-mac", hub: hub), b = mac("laptop", hub: hub)
        a.open("one")
        a.ownership?.flush()
        syncShared(a, b)
        XCTAssertFalse(owns(b))
        let later = Date().addingTimeInterval(SessionOwners.hostMaxSilence + 60)
        XCTAssertTrue(owns(b, now: later), "the owner's Mac has gone quiet, so the local rules decide")
        let soon = Date().addingTimeInterval(SessionOwners.hostMaxSilence - 60)
        XCTAssertFalse(owns(b, now: soon))
    }

    func testABadRemoteFileCountsAsEmptyAndIsReplaced() throws {
        let hub = HubFile()
        let a = mac("hub-mac", hub: hub)
        a.open("one")
        a.ownership?.flush()
        for bad in [Data("not json".utf8), Data("[1,2,3]".utf8), Data(#"{"entries": 7, "hosts": []}"#.utf8),
                    Data(repeating: 0x20, count: SessionOwners.maximumFileSize + 1)] {
            hub.raw = bad
            syncShared(a)
            XCTAssertTrue(owns(a))
            let healed = SessionOwners.SharedFile.decode(hub.raw)
            XCTAssertEqual(healed.entries["sess-1"]?.host, "hub-mac")
            XCTAssertNotNil(healed.hosts["hub-mac"])
        }
    }

    func testAClaimThatCannotBeReadOrIsFromTheFutureIsSkipped() {
        let hub = HubFile()
        let a = mac("hub-mac", hub: hub)
        a.open("one")
        a.ownership?.flush()
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let now = ISO8601DateFormatter().string(from: Date())
        hub.raw = Data("""
        {"version":1,"entries":{"sess-1":{"app":"app.evil","at":"\(future)","host":"laptop"},
          "x":{"app":"","at":"\(now)"}, "y":"nope", "z":{"app":"app.z","at":"\(now)","host":"bad host;rm"}},
         "hosts":{"laptop":"\(future)"}}
        """.utf8)
        syncShared(a)
        XCTAssertTrue(owns(a))
        let held = SessionOwners.SharedFile.decode(hub.raw)
        XCTAssertEqual(held.entries["sess-1"]?.app, "app.a")
        XCTAssertNil(held.entries["x"])
        XCTAssertNil(held.entries["z"]?.host, "an unsafe host name is dropped")
        XCTAssertNil(held.hosts["laptop"])
    }

    func testAHubThatCannotBeReachedLeavesTheLocalClaimsAlone() {
        let hub = DownHub()
        let a = mac("hub-mac", hub: hub)
        a.open("one")
        a.ownership?.flush()
        syncShared(a)
        XCTAssertTrue(owns(a))
        XCTAssertTrue(a.ownership!.shared.hosts.isEmpty)
    }

    func testTheNewestClaimOfAKeyWinsTheSameOnEveryMac() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let old = SessionOwners.Entry(app: "app.a", at: t, host: "hub-mac")
        let new = SessionOwners.Entry(app: "app.b", at: t.addingTimeInterval(5), host: "laptop")
        XCTAssertEqual(SessionOwners.mergeEntries(["k": old], ["k": new], now: t)["k"], new)
        XCTAssertEqual(SessionOwners.mergeEntries(["k": new], ["k": old], now: t)["k"], new)
        let tie = SessionOwners.Entry(app: "app.a", at: t, host: "laptop")
        XCTAssertEqual(SessionOwners.mergeEntries(["k": old], ["k": tie], now: t)["k"],
                       SessionOwners.mergeEntries(["k": tie], ["k": old], now: t)["k"])
    }

    func testTheSharedFilesAreWrittenForTheirUserAlone() throws {
        let file = folder.appendingPathComponent("hub/agentsmate/session-owner-shared.json")
        try LocalSharedLaneTransport(file: file, isPrivate: true).write(Data("{}".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(folderMode, 0o700)
        let ssh = SSHSharedLaneTransport(hub: "hub-mac", appID: "session-owner",
                                         relativePath: SharedLanePaths.ownersRelativePath, isPrivate: true)
        XCTAssertTrue(ssh.writeCommand.hasPrefix("umask 077 && "))
        XCTAssertTrue(ssh.readCommand.contains("session-owner-shared.json"))
    }

    func testWithoutAHostsRegistryNothingIsShared() {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, displayedExportFile: nil,
                                                  sessionOwnerFile: folder.appendingPathComponent("solo/session-owner.json"),
                                                  ownerAppID: "app.a", isLaneShared: { _ in true })
        let store = AgentLaneStore(configuration: config, backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-shared-owner-\(UUID().uuidString)")!)
        XCTAssertNil(store.ownership?.sharing)
    }
}
