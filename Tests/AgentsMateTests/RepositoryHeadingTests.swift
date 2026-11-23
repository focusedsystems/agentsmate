import XCTest
@testable import AgentsMate

@MainActor
final class RepositoryHeadingTests: XCTestCase {
    private func lane(_ id: String, _ path: String, section: String?, closable: Bool = false) -> AgentLane {
        AgentLane(id: id, title: id.uppercased(), directory: URL(fileURLWithPath: path), backendID: "agent",
                  isClosable: closable, section: section)
    }

    private var lanes: [AgentLane] {
        [lane("api", "/w/api", section: "Platform"), lane("web", "/w/web", section: "Platform"),
         lane("infra", "/w/infra", section: "Cloud"),
         lane("api-2", "/w/api", section: "Platform", closable: true)]
    }

    func testOneHeadingPerFolderInSectionOrder() {
        let groups = LaneLayout().repositoryGroups(for: lanes, defaultOrder: []) { _ in nil }
        XCTAssertEqual(groups.compactMap(\.repository), ["/w/api", "/w/web", "/w/infra"])
        XCTAssertEqual(groups.first?.lanes.map(\.id), ["api", "api-2"], "a folder's lanes share its heading")
        XCTAssertEqual(groups.first?.title, "API", "the app's lane names the heading")
        XCTAssertEqual(groups.first?.headingLaneID, "api")
        XCTAssertEqual(groups.first?.collapseKey, LaneLayout.repositoryCollapseKey("/w/api"))
    }

    func testTheAppsOrderAppliesUntilThePersonMovesOne() {
        var layout = LaneLayout()
        let order = ["/w/infra", "/w/web/"]
        XCTAssertEqual(layout.repositoryKeys(for: lanes, defaultOrder: order), ["/w/infra", "/w/web", "/w/api"])
        layout.moveRepository("/w/api", before: "/w/infra", current: layout.repositoryKeys(for: lanes, defaultOrder: order))
        XCTAssertEqual(layout.repositoryKeys(for: lanes, defaultOrder: order), ["/w/api", "/w/infra", "/w/web"],
                       "the person's order wins")
        layout.moveRepository("/w/api", by: 1, current: layout.repositoryKeys(for: lanes, defaultOrder: order))
        XCTAssertEqual(layout.repositoryKeys(for: lanes, defaultOrder: order), ["/w/infra", "/w/api", "/w/web"])
        layout.repositoryOrder = []
        XCTAssertEqual(layout.repositoryKeys(for: lanes, defaultOrder: order), ["/w/infra", "/w/web", "/w/api"])
    }

    func testPinnedLanesLeaveTheirHeadingButKeepTheirPlaceInTheOrder() {
        var layout = LaneLayout()
        layout.setPinned("web", true)
        let groups = layout.repositoryGroups(for: lanes, defaultOrder: []) { _ in nil }
        XCTAssertTrue(groups[0].isPinned)
        XCTAssertEqual(groups.compactMap(\.repository), ["/w/api", "/w/infra"], "a folder with only pinned lanes has no heading")
        XCTAssertEqual(layout.repositoryKeys(for: lanes, defaultOrder: []), ["/w/api", "/w/web", "/w/infra"])
    }

    func testOldLayoutsDecodeWithNoOrder() throws {
        let layout = try JSONDecoder().decode(LaneLayout.self, from: Data(#"{"sections":["A"]}"#.utf8))
        XCTAssertEqual(layout.repositoryOrder, [])
    }

    private func store(order: [String] = []) -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  defaultRepositoryOrder: order)
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend(id: "agent", displayName: "Agent", command: "true")],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-repos-\(UUID().uuidString)")!)
        store.sync(lanes: Array(lanes.prefix(3)))
        return store
    }

    func testTheStoreHeadsTheListWithRepositories() {
        let store = store(order: ["/w/infra"])
        XCTAssertEqual(store.groups.compactMap(\.repository), ["/w/infra", "/w/api", "/w/web"])
        XCTAssertEqual(store.orderedRepositories(["/w/web", "/elsewhere", "/w/infra"]), ["/w/infra", "/w/web", "/elsewhere"])
        store.setRepositoryOrder(["/w/web", "/w/api"])
        XCTAssertTrue(store.hasCustomRepositoryOrder)
        XCTAssertEqual(store.repositoryOrder, ["/w/web", "/w/api", "/w/infra"], "a settings drag reorders the headings")
        store.moveRepository("/w/infra", by: -2)
        XCTAssertEqual(store.repositoryOrder, ["/w/infra", "/w/web", "/w/api"], "and a heading move reorders the list")
        store.resetRepositoryOrder()
        XCTAssertFalse(store.hasCustomRepositoryOrder)
        XCTAssertEqual(store.repositoryOrder, ["/w/infra", "/w/api", "/w/web"])
        store.setAllCollapsed(true)
        XCTAssertTrue(store.layout.collapsed.contains(LaneLayout.repositoryCollapseKey("/w/api")))
    }

    func testSectionsHeadTheListWhenAnAppTurnsHeadingsOff() {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  groupsByRepository: false)
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend(id: "agent", displayName: "Agent", command: "true")],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-repos-\(UUID().uuidString)")!)
        store.sync(lanes: Array(lanes.prefix(3)))
        XCTAssertEqual(store.groups.compactMap(\.section), ["Platform", "Cloud"])
        XCTAssertTrue(store.groups.allSatisfy { $0.repository == nil })
    }

    func testTheSamePathOnTwoHostsHeadsTwoHeadingsAndPlusStartsOnlyWhereItReallyRuns() async {
        var asked = 0
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  chooseFolder: { _ in asked += 1; return nil })
        let remote = CommandLaneBackend.tmuxLane(id: "remote", displayName: "Remote", command: "w", statusAgent: "claude",
                                                 tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"], host: "build-mac"))
        let wrapper = CommandLaneBackend(id: "wrap", displayName: "Wrap", command: "w", passesDirectory: true)
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend(id: "agent", displayName: "Agent", command: "true"), remote, wrapper],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-repos-\(UUID().uuidString)")!)
        var other = AgentLane(id: "api-other", title: "API", directory: URL(fileURLWithPath: "/w/api"), backendID: "wrap")
        other.host = "other-mac"
        let wrapped = AgentLane(id: "web", title: "Web", directory: URL(fileURLWithPath: "/w/web"), backendID: "wrap")
        store.sync(lanes: [lane("api", "/w/api", section: "Platform"), other, wrapped])
        let found = store.groups.filter { $0.repository != nil }
        let order = ["/w/api", "other-mac:/w/api", "/w/web"]
        let headings = order.compactMap { key in found.first { $0.repository == key } }
        XCTAssertEqual(headings.count, 3, "the same path on two hosts heads two headings")
        XCTAssertEqual(headings.map(\.host), [nil, "other-mac", nil])
        XCTAssertEqual(headings.map { $0.lanes.map(\.id) }, [["api"], ["api-other"], ["web"]])

        XCTAssertEqual(store.newLaneHost(in: headings[1], backendID: "wrap"), "other-mac")
        XCTAssertNil(store.newLaneHost(in: headings[1], backendID: "agent"), "a backend that ignores the host is not shown as running there")
        XCTAssertNil(store.newLaneHost(in: headings[0], backendID: "wrap"))

        let made = await store.newLane(in: headings[1], backendID: "wrap", focus: false)
        XCTAssertEqual(made?.lane.host, "other-mac", "the + starts a wrapper lane on the heading's host")
        XCTAssertEqual(made?.lane.path, "/w/api")
        XCTAssertEqual(asked, 0)

        let local = await store.newLane(in: headings[0], backendID: "agent", focus: false)
        XCTAssertNil(local?.lane.host)
        XCTAssertEqual(asked, 0, "same machine as the heading's rows: no question")

        let ignoresHost = await store.newLaneIfAsked(store, headings[1], "agent")
        XCTAssertNil(ignoresHost, "a backend that ignores the heading's host asks for a folder")
        XCTAssertEqual(asked, 1)

        let elsewhere = await store.newLaneIfAsked(store, headings[0], "remote")
        XCTAssertNil(elsewhere, "a backend on another machine asks for a folder")
        XCTAssertEqual(asked, 2)

        let wrapperDefault = await store.newLaneIfAsked(store, headings[2], "agent")
        XCTAssertNil(wrapperDefault, "a wrapper heading's default machine is not this Mac for certain")
        XCTAssertEqual(asked, 3)
    }
}

private extension AgentLaneStore {
    func newLaneIfAsked(_ store: AgentLaneStore, _ group: LaneGroup, _ backendID: String) async -> AgentLaneSession? {
        await store.newLane(in: group, backendID: backendID, focus: false)
    }
}
