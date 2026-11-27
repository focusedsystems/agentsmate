import XCTest
@testable import AgentsMate
import AgentsMateStatus

@MainActor
final class RemoteStatusTests: XCTestCase {
    private var folder: URL!
    private let work = "/tmp/remote-status-work"

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-status-\(UUID().uuidString)", isDirectory: true)
        let url = folder!
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    }

    /// The laptop: a client of the hub, its lane runs on the hub.
    private func laptop(local: [LaneStatus] = []) throws -> AgentLaneStore {
        let directory = LaneStatusDirectory(url: folder.appendingPathComponent("lanes", isDirectory: true))
        for record in local { try directory.write(record) }
        let hosts = AgentHosts(hosts: [.init(name: "hub-mac", role: .hub, platform: "mac"),
                                       .init(name: "laptop", role: .client, platform: "mac")], selfName: "laptop")
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, hostSessions: HostSessionsConfiguration(ssh: "/usr/bin/false", hosts: hosts),
                                                  liveSnapshotFile: nil, opensActiveOnly: false, displayedExportFile: nil,
                                                  sessionOwnerFile: nil)
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend.tmuxLane(id: "agent", displayName: "Agent", command: "true",
                                                                          statusAgent: "claude")],
                                   statusFeed: LaneStatusFeed(directory: directory),
                                   defaults: UserDefaults(suiteName: "agentsmate-remote-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "one", title: "one", directory: URL(fileURLWithPath: work), backendID: "agent")])
        return store
    }

    private func record(_ state: LaneState, event: String = "Stop", age: TimeInterval = 0) -> LaneStatus {
        LaneStatus(agent: "claude", state: state, lane: "remote-status-work", directory: work, sessionID: "conv-1",
                   event: event, updatedAt: Date().addingTimeInterval(-age))
    }

    private func listing(_ records: [LaneStatus]) -> HostSessionListing { HostSessionListing(records: records) }

    private func row(_ store: AgentLaneStore) throws -> DisplayedExport.Row {
        try XCTUnwrap(store.displayedExport().rows.first { $0.laneID == "one" })
    }

    func testRemoteWorkingShowsWorkingAndAttachedHereIsASeparateMark() throws {
        let store = try laptop()
        XCTAssertEqual(store.remoteStatusHost(for: store.lanes[0]), "hub-mac")
        store.receivedStatus(listing([record(.running, event: "PreToolUse")]), from: "hub-mac")
        store.open("one")
        let session = try XCTUnwrap(store.sessions["one"])
        XCTAssertTrue(session.isStarted, "a terminal is open here")
        XCTAssertEqual(session.status, .running)
        let shown = try row(store)
        XCTAssertEqual(shown.state, .working)
        XCTAssertEqual(shown.attachedHere, session.isAttached)
        XCTAssertEqual(shown.statusHost, "hub-mac")
        XCTAssertNotNil(shown.statusAt)
    }

    func testRemoteIdleBeatsALocalStaleNeedsYouRecord() throws {
        let store = try laptop(local: [record(.waitingForInput, event: "Notification", age: 600)])
        XCTAssertEqual(store.sessions["one"]?.record?.state, .waitingForInput, "before the hub answers, the local record stands")
        store.receivedStatus(listing([record(.done, age: 30)]), from: "hub-mac")
        XCTAssertEqual(store.sessions["one"]?.status, .done)
        XCTAssertEqual(try row(store).state, .idle)
    }

    func testALocalRecordNewerThanTheReadingStillCounts() throws {
        let store = try laptop(local: [record(.waitingForInput, event: "Notification", age: 0)])
        store.receivedStatus(listing([record(.done, age: 30)]), from: "hub-mac", now: Date().addingTimeInterval(-10))
        XCTAssertEqual(try row(store).state, .needsYou)
    }

    func testAnUnreachableHostIsUnknownNeverActive() throws {
        let store = try laptop(local: [record(.waitingForInput, event: "Notification", age: 600)])
        store.receivedStatus(nil, from: "hub-mac")
        XCTAssertEqual(store.sessions["one"]?.status, .unknown)
        XCTAssertEqual(try row(store).state, .unknown)
        XCTAssertFalse(try row(store).state.claimsRunning)
    }

    func testAReadingThatGrowsTooOldIsNoLongerBelieved() throws {
        let store = try laptop()
        store.receivedStatus(listing([record(.running)]), from: "hub-mac", now: Date().addingTimeInterval(-300))
        XCTAssertEqual(try row(store).state, .unknown, "the host has been quiet for five minutes")
        store.receivedStatus(listing([record(.running)]), from: "hub-mac")
        XCTAssertEqual(try row(store).state, .working)
    }

    func testALaneWithNoRecordIsNeverShownAsAttachedFromThisMac() throws {
        let store = try laptop()
        store.receivedStatus(listing([]), from: "hub-mac")
        store.open("one")
        XCTAssertNotEqual(store.sessions["one"]?.status, .attached)
        XCTAssertEqual(try row(store).state, .notAttached)
    }

    func testTheListingCarriesTheHostsStatusFiles() throws {
        let marks = HostSessions.Marks(nonce: "n0nce")
        let file = #"{"agent":"claude","state":"running","lane":"x","event":"PreToolUse","updatedAt":"2026-11-26T10:00:00Z"}"#
        let out = "[]\n" + marks.tmux + "\nrepo\n" + marks.bindings + "\n" + marks.records + "\n" + file + "\nnot json\n\n"
            + marks.status + "0\n" + marks.end + "\n"
        let parsed = try XCTUnwrap(HostSessions.parse(out, marks: marks))
        XCTAssertEqual(parsed.records.map(\.state), [.running], "a line that is not a record is skipped")
        XCTAssertTrue(parsed.bindingsKnown)
        let script = HostSessions.script(HostSessionsConfiguration(bindingsCommand: "agent-lane-bindings"), marks: marks, statusOnly: true)
        XCTAssertTrue(script.contains(marks.records))
        XCTAssertFalse(script.contains("agent-lane-bindings"), "the light ask skips the bindings command")
        XCTAssertTrue(HostSessions.script(HostSessionsConfiguration(bindingsCommand: "agent-lane-bindings"), marks: marks)
            .contains("agent-lane-bindings"))
    }
}
