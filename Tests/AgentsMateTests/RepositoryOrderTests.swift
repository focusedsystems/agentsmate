import XCTest
@testable import AgentsMate

@MainActor
final class RepositoryOrderTests: XCTestCase {
    private func lane(_ id: String, section: String?) -> AgentLane {
        AgentLane(id: id, title: id.uppercased(), directory: URL(fileURLWithPath: "/w/" + id), backendID: "agent", section: section)
    }

    private func store(order: [String] = [], headings: Bool = true) -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  showsSectionHeadings: headings, defaultRepositoryOrder: order)
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend(id: "agent", displayName: "Agent", command: "true")],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-order-\(UUID().uuidString)")!)
        store.sync(lanes: [lane("api", section: "Platform"), lane("web", section: "Platform"),
                           lane("infra", section: "Cloud"), lane("dns", section: "Cloud")])
        return store
    }

    func testSectionsHeadTheListWithReposAsRows() {
        let store = store()
        XCTAssertEqual(store.groups.map(\.section), ["Platform", "Cloud"])
        XCTAssertEqual(store.groups.map { $0.lanes.map(\.id) }, [["api", "web"], ["infra", "dns"]])
    }

    func testTheAppsOrderSetsSectionsAndRowsUntilThePersonMovesOne() {
        let store = store(order: ["/w/dns", "/w/infra", "/w/web", "/w/api"])
        XCTAssertEqual(store.groups.map(\.section), ["Cloud", "Platform"], "a section comes where its first lane does")
        XCTAssertEqual(store.repositoryOrder, ["/w/dns", "/w/infra", "/w/web", "/w/api"])
        XCTAssertFalse(store.hasCustomRepositoryOrder)

        store.setRepositoryOrder(["/w/infra", "/w/dns"])
        XCTAssertEqual(store.groups.first?.lanes.map(\.id), ["infra", "dns"], "a settings drag reorders rows in their section")
        store.setSectionOrder(["Platform", "Cloud"])
        XCTAssertEqual(store.groups.map(\.section), ["Platform", "Cloud"])
        store.moveSection("Platform", by: 1)
        XCTAssertEqual(store.sectionNames, ["Cloud", "Platform"], "moving a section in the sidebar is the same order")
        XCTAssertTrue(store.hasCustomRepositoryOrder)
        XCTAssertEqual(store.orderedRepositories(["/w/api", "/elsewhere", "/w/infra"]), ["/w/infra", "/w/api", "/elsewhere"])

        store.resetRepositoryOrder()
        XCTAssertFalse(store.hasCustomRepositoryOrder)
        XCTAssertEqual(store.repositoryOrder, ["/w/dns", "/w/infra", "/w/web", "/w/api"])
    }

    func testRowsKeepTheirSectionInTheSettingsList() {
        let store = store()
        XCTAssertEqual(store.section(ofRepository: "/w/dns/"), "Cloud")
        XCTAssertNil(store.section(ofRepository: "/w/nowhere"))
    }

    func testHeadingsCanBeTurnedOff() {
        XCTAssertFalse(store(headings: false).configuration.showsSectionHeadings)
        XCTAssertTrue(store().configuration.showsSectionHeadings)
    }
}
