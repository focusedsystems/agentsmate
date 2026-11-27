import XCTest
@testable import AgentsMate

final class LaneRunsOnTests: XCTestCase {
    func testALocalLaneOnTheHubHasNoMarker() {
        XCTAssertNil(LaneRunsOn.decide(runsOn: "hub", isThisMac: true, thisMacName: "hub", isHub: true,
                                       meantFor: "hub", meantIsRunHost: true))
    }

    func testALocalLaneOnAnotherMacSaysThisMac() {
        let marker = LaneRunsOn.decide(runsOn: "laptop", isThisMac: true, thisMacName: "laptop", isHub: false,
                                       meantFor: "hub", meantIsRunHost: true)
        XCTAssertEqual(marker?.kind, .thisMac)
        XCTAssertEqual(marker?.label, "This Mac")
        XCTAssertEqual(marker?.hostName, "laptop")
        XCTAssertNil(marker?.meantFor)
    }

    func testALocalLaneMeantForTheHubSaysSo() {
        let marker = LaneRunsOn.decide(runsOn: "laptop", isThisMac: true, thisMacName: "laptop", isHub: false,
                                       meantFor: "hub", meantIsRunHost: false)
        XCTAssertEqual(marker?.meantFor, "hub")
        XCTAssertEqual(marker?.help, "Runs on this Mac (laptop). Meant to run on hub")
    }

    func testARemoteLaneNamesItsHostWhoeverIsAsking() {
        for isHub in [true, false] {
            let marker = LaneRunsOn.decide(runsOn: "user@far-mac", isThisMac: false, thisMacName: "x", isHub: isHub,
                                           meantFor: "far-mac", meantIsRunHost: true)
            XCTAssertEqual(marker, LaneRunsOn(kind: .remote, hostName: "far-mac"))
            XCTAssertEqual(marker?.label, "far-mac")
        }
    }

    func testARemoteLaneOffItsRegistryHostSaysWhereItWasMeant() {
        let marker = LaneRunsOn.decide(runsOn: "mini", isThisMac: false, thisMacName: "laptop", isHub: false,
                                       meantFor: "hub", meantIsRunHost: false)
        XCTAssertEqual(marker?.meantFor, "hub")
    }

    func testNoRegistryMeansNoLocalMarker() {
        XCTAssertNil(LaneRunsOn.decide(runsOn: "x", isThisMac: true, thisMacName: "x", isHub: true,
                                       meantFor: nil, meantIsRunHost: true))
    }
}

@MainActor
final class LaneRunsOnStoreTests: XCTestCase {
    private func store(hub: String, selfName: String) -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        let store = AgentLaneStore(configuration: config, backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-runson-\(UUID().uuidString)")!)
        store.liveSelfNameOverride = selfName
        store.setAgentHostsForTesting(AgentHosts(hosts: [.init(name: hub, role: .hub), .init(name: "laptop", role: .client)],
                                                 selfName: selfName))
        store.sync(lanes: [AgentLane(id: "a", title: "a", directory: URL(fileURLWithPath: "/w/a"), backendID: CommandLaneBackend.shell.id)])
        return store
    }

    func testTheHubShowsNoMarkerAndExportsNone() throws {
        let store = store(hub: "hub", selfName: "hub")
        XCTAssertNil(store.laneRunsOn(for: try XCTUnwrap(store.lanes.first)))
        XCTAssertNil(store.displayedExport().rows.first?.runsOn)
    }

    func testTheLaptopShowsThisMacMeantForTheHub() throws {
        let store = store(hub: "hub", selfName: "laptop")
        let row = try XCTUnwrap(store.displayedExport().rows.first)
        XCTAssertEqual(row.runsOnKind, "this_mac")
        XCTAssertEqual(row.runsOn, "laptop")
        XCTAssertEqual(row.meantFor, "hub")
    }
}
