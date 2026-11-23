import XCTest
@testable import AgentsMate
import AgentsMateStatus

final class HomeGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func item(_ id: String, _ status: LaneDisplayStatus, active: Bool = true, unread: Bool = false,
                      ago: TimeInterval? = nil) -> AgentHomeItem {
        AgentHomeItem(id: id, status: status, isActive: active, unread: unread,
                      lastActivity: ago.map { now.addingTimeInterval(-$0) })
    }

    func testSectionsFollowTheSidebarFilters() {
        XCTAssertEqual(AgentHome.section(for: item("a", .waitingForInput), now: now), .needsYou)
        XCTAssertEqual(AgentHome.section(for: item("a", .permissionRequested), now: now), .needsYou)
        XCTAssertEqual(AgentHome.section(for: item("a", .running), now: now), .working)
        XCTAssertEqual(AgentHome.section(for: item("a", .idle), now: now), .recent)
        XCTAssertEqual(AgentHome.section(for: item("a", .attached), now: now), .recent)
    }

    func testLanesWithNothingRunningAreLeftOutUnlessRecentOrUnread() {
        XCTAssertNil(AgentHome.section(for: item("a", .notOpened, active: false), now: now))
        XCTAssertNil(AgentHome.section(for: item("a", .detached, active: false, ago: 60), now: now))
        XCTAssertEqual(AgentHome.section(for: item("a", .done, active: false, ago: 3600), now: now), .recent)
        XCTAssertNil(AgentHome.section(for: item("a", .done, active: false, ago: AgentHome.recentWindow + 1), now: now))
        XCTAssertEqual(AgentHome.section(for: item("a", .notOpened, active: false, unread: true), now: now), .recent)
    }

    func testGroupsComeInSectionOrderNewestFirst() {
        let items = [
            item("idle", .idle, ago: 10),
            item("old-run", .running, ago: 500),
            item("ask", .waitingForInput, ago: 30),
            item("new-run", .running, ago: 5),
            item("quiet", .attached),
            item("gone", .notOpened, active: false),
            item("fresh-idle", .idle, ago: 1),
        ]
        let groups = AgentHome.grouped(items, now: now)
        XCTAssertEqual(groups.map(\.section), [.needsYou, .working, .recent])
        XCTAssertEqual(groups.map { $0.items.map(\.id) }, [["ask"], ["new-run", "old-run"], ["fresh-idle", "idle", "quiet"]])
        XCTAssertEqual(AgentHome.totals(groups), .init(needsYou: 1, working: 2, recent: 3))
    }

    func testEmptySectionsAreLeftOut() {
        let groups = AgentHome.grouped([item("r", .running, ago: 1)], now: now)
        XCTAssertEqual(groups.map(\.section), [.working])
        XCTAssertTrue(AgentHome.grouped([], now: now).isEmpty)
    }

    func testAgeIsShort() {
        XCTAssertEqual(AgentHomeRow.age(of: now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(AgentHomeRow.age(of: now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(AgentHomeRow.age(of: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(AgentHomeRow.age(of: now.addingTimeInterval(-3 * 86_400), now: now), "3d")
    }

    func testLoadingCountsHostsThatAnswered() {
        var loading = AgentHomeLoading(hosts: [.init(name: "a", state: .answered), .init(name: "b", state: .asking)])
        XCTAssertTrue(loading.isLoading)
        XCTAssertEqual(loading.hostsAnswered, 1)
        loading.hosts[1].state = .unreachable
        XCTAssertFalse(loading.isLoading)
        XCTAssertEqual(loading.hostsAnswered, 2)
    }
}

@MainActor
final class HomeLaunchTests: XCTestCase {
    private func makeStore(showsHome: Bool = true, launchShows: AgentsLaunchDestination = .home,
                           defaults: UserDefaults? = nil) -> AgentLaneStore {
        let defaults = defaults ?? UserDefaults(suiteName: "agentsmate-home-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "Test", sessionFileDirectory: nil,
                                                        findsDetachedSessions: false, sharedLanes: nil,
                                                        showsHome: showsHome, launchShows: launchShows),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "shell"),
                           AgentLane(id: "b", title: "B", backendID: "shell")])
        return store
    }

    func testLaunchLandsOnHomeAndAttachesNothing() {
        let store = makeStore()
        store.openSelectedOnShow()
        XCTAssertTrue(store.isHomeShown)
        XCTAssertEqual(store.selectedID, "a")
        XCTAssertFalse(store.sessions["a"]!.isStarted)
        // Showing the lanes again keeps Home rather than attaching.
        store.openSelectedOnShow()
        XCTAssertTrue(store.isHomeShown)
        XCTAssertFalse(store.sessions["a"]!.isStarted)
    }

    func testLaunchCanStillShowTheSelectedLane() {
        let store = makeStore(launchShows: .selectedLane)
        store.openSelectedOnShow()
        XCTAssertFalse(store.isHomeShown)
    }

    func testHomeOffNeverShows() {
        let store = makeStore(showsHome: false)
        store.openSelectedOnShow()
        XCTAssertFalse(store.isHomeShown)
        store.showHome()
        XCTAssertFalse(store.isHomeShown)
    }

    func testOpeningALaneLeavesHomeAndHomeIsSaved() {
        let defaults = UserDefaults(suiteName: "agentsmate-home-\(UUID().uuidString)")!
        let store = makeStore(defaults: defaults)
        store.openSelectedOnShow()
        store.open("b", focus: false)
        XCTAssertFalse(store.isHomeShown)
        XCTAssertEqual(store.selectedID, "b")
        store.showHome()
        XCTAssertTrue(store.isHomeShown)
        XCTAssertEqual(store.selectedID, "b")
        XCTAssertTrue(defaults.bool(forKey: store.keys.showingHome))
        let again = makeStore(launchShows: .selectedLane, defaults: defaults)
        XCTAssertTrue(again.isHomeShown)
        again.openSelectedOnShow()
        XCTAssertTrue(again.isHomeShown)
    }

    func testHomeHasItsOwnRebindableShortcut() {
        let binding = LaneShortcutBindings().binding(for: .home)
        XCTAssertEqual(binding, LaneKeyBinding("h", command: true, shift: true))
        XCTAssertNil(LaneShortcutBindings().conflict(for: binding!, excluding: .home))
    }
}
