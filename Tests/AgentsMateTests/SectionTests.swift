import XCTest
import SwiftUI
@testable import AgentsMate

@MainActor
final class SectionLayoutTests: XCTestCase {
    private func lane(_ id: String, section: String? = nil) -> AgentLane {
        AgentLane(id: id, title: id, backendID: "s", section: section)
    }

    func testDragPutsASectionBeforeAnother() {
        let lanes = [lane("a", section: "One"), lane("b", section: "Two"), lane("c", section: "Three")]
        var layout = LaneLayout()
        layout.moveSection("Three", before: "One", lanes: lanes)
        XCTAssertEqual(layout.orderedSections(for: lanes), ["Three", "One", "Two"])
        layout.moveSection("Three", before: nil, lanes: lanes)
        XCTAssertEqual(layout.orderedSections(for: lanes), ["One", "Two", "Three"])
        layout.moveSection("One", before: "One", lanes: lanes)
        layout.moveSection("Nope", before: "One", lanes: lanes)
        XCTAssertEqual(layout.orderedSections(for: lanes), ["One", "Two", "Three"])
    }

    func testEveryGroupHasAFoldKeyAndCollapseOthersKeepsOne() {
        let lanes = [lane("a"), lane("b", section: "Work"), lane("c", section: "Home"), lane("d")]
        var layout = LaneLayout()
        layout.setPinned("d", true)
        let groups = layout.groups(for: lanes) { _ in nil }
        XCTAssertEqual(groups.map(\.collapseKey), [LaneLayout.pinnedSection, LaneLayout.unsectionedKey, "Work", "Home"])
        XCTAssertEqual(groups.map(\.title), ["Pinned", nil, "Work", "Home"])
        layout.collapsed = ["Work"]
        layout.collapseOthers(than: "Work", groups: groups)
        XCTAssertEqual(layout.collapsed, [LaneLayout.pinnedSection, LaneLayout.unsectionedKey, "Home"])
        layout.collapseOthers(than: LaneLayout.unsectionedKey, groups: groups)
        XCTAssertFalse(layout.collapsed.contains(LaneLayout.unsectionedKey))
    }

    func testNoSectionCanTakeTheUnsectionedKey() {
        var layout = LaneLayout()
        layout.addSection(LaneLayout.unsectionedKey)
        XCTAssertTrue(layout.sections.isEmpty)
    }

    func testSearchFindsLanesBySectionName() {
        let lanes = [lane("a"), lane("b", section: "Billing"), lane("c", section: "Billing"), lane("d", section: "Docs")]
        var layout = LaneLayout()
        layout.setPinned("c", true)
        layout.collapsed = ["Billing"]
        let groups = layout.groups(for: lanes) { _ in nil }
        let hits = AgentLaneSidebar<EmptyView>.lanesInSections(matching: "bill", groups: groups, section: layout.section(of:))
        XCTAssertEqual(hits, ["b", "c"])
        XCTAssertEqual(layout.collapsed, ["Billing"], "searching leaves the saved fold alone")
        XCTAssertTrue(AgentLaneSidebar<EmptyView>.lanesInSections(matching: "zzz", groups: groups,
                                                                  section: layout.section(of:)).isEmpty)
    }
}

final class StatusFilterTests: XCTestCase {
    func testOnlyBlockedLanesWantYou() {
        let all: [LaneDisplayStatus] = [.notOpened, .attached, .running, .waitingForInput, .permissionRequested, .done, .idle, .detached]
        XCTAssertEqual(all.filter(LaneStatusFilter.wantsYou), [.waitingForInput, .permissionRequested])
        let lanes: [LaneDisplayStatus] = [.done, .done, .attached, .idle, .running, .permissionRequested]
        XCTAssertEqual(lanes.filter { LaneStatusFilter.needsYou.admits(isActive: true, status: $0) }.count, 1)
    }

    func testIdleIsAliveButNotWorkingOrWaiting() {
        XCTAssertTrue(LaneStatusFilter.idle.admits(isActive: true, status: .done))
        XCTAssertTrue(LaneStatusFilter.idle.admits(isActive: true, status: .attached))
        XCTAssertFalse(LaneStatusFilter.idle.admits(isActive: true, status: .running))
        XCTAssertFalse(LaneStatusFilter.idle.admits(isActive: true, status: .waitingForInput))
        XCTAssertFalse(LaneStatusFilter.idle.admits(isActive: true, status: .permissionRequested))
        XCTAssertFalse(LaneStatusFilter.idle.admits(isActive: false, status: .notOpened))
    }

    func testFiltersThatWouldHideEverythingTurnOff() {
        let lanes: [LaneStatusFilter.Lane] = [.init(isActive: true, status: .running), .init(isActive: true, status: .done)]
        XCTAssertEqual(LaneStatusFilter.settled([.running], newest: nil, lanes: lanes), [.running])
        // Running and Needs You together match nothing: the chip just
        // turned on stays, the other goes.
        XCTAssertEqual(LaneStatusFilter.settled([.running, .needsYou], newest: .running, lanes: lanes), [.running])
        // A lane stops running while Running is on: the filter clears.
        let stopped: [LaneStatusFilter.Lane] = [.init(isActive: true, status: .done), .init(isActive: false, status: .notOpened)]
        XCTAssertEqual(LaneStatusFilter.settled([.running], newest: nil, lanes: stopped), [])
        XCTAssertEqual(LaneStatusFilter.settled([.running, .idle], newest: .idle, lanes: stopped), [.idle])
        XCTAssertEqual(LaneStatusFilter.settled([], newest: nil, lanes: []), [])
    }

    func testUnreadFollowsTheBlueDot() {
        XCTAssertTrue(LaneStatusFilter.unread.admits(.init(isActive: true, status: .done, unread: true)))
        XCTAssertTrue(LaneStatusFilter.unread.admits(.init(isActive: false, status: .notOpened, unread: true)))
        XCTAssertFalse(LaneStatusFilter.unread.admits(.init(isActive: true, status: .waitingForInput)))
        // Unread with nothing unread clears itself.
        let read: [LaneStatusFilter.Lane] = [.init(isActive: true, status: .done)]
        XCTAssertEqual(LaneStatusFilter.settled([.unread], newest: .unread, lanes: read), [])
        XCTAssertEqual(LaneStatusFilter.settled([.unread, .idle], newest: .unread,
                                                lanes: [.init(isActive: true, status: .done, unread: true)]), [.unread, .idle])
    }
}

@MainActor
final class NewLaneInSectionTests: XCTestCase {
    /// A chooser that records where it opened and answers with `answer`.
    private final class Chooser {
        var answer: URL?
        var openedAt: [URL?] = []
    }

    private func store(_ chooser: Chooser, backends: [any LaneBackend]? = nil) -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil,
                                                  findsDetachedSessions: false, chooseFolder: { start in
            chooser.openedAt.append(start)
            return chooser.answer
        }, groupsByRepository: false)
        let store = AgentLaneStore(configuration: config,
                                   backends: backends ?? [CommandLaneBackend(id: "agent", displayName: "Agent", command: "true")],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-new-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "a", title: "A", directory: URL(fileURLWithPath: "/w/a"), backendID: "agent", section: "Work"),
                           AgentLane(id: "b", title: "B", directory: URL(fileURLWithPath: "/w/b"), backendID: "agent", section: "Work"),
                           AgentLane(id: "c", title: "C", directory: URL(fileURLWithPath: "/w/c"), backendID: "agent")])
        return store
    }

    private func group(_ store: AgentLaneStore, _ section: String?) -> LaneGroup {
        store.groups.first { $0.section == section && !$0.isPinned }!
    }

    func testCancelChangesNothing() async {
        let chooser = Chooser()
        let store = store(chooser)
        let before = (store.lanes, store.layout, store.selectedID)
        let added = await store.newLane(in: group(store, "Work"), backendID: "agent", focus: false)
        XCTAssertNil(added)
        XCTAssertEqual(store.lanes, before.0)
        XCTAssertEqual(store.layout, before.1)
        XCTAssertEqual(store.selectedID, before.2)
        XCTAssertEqual(chooser.openedAt, [URL(fileURLWithPath: "/w/a")], "no selection: the first member's folder")
    }

    func testChooserStartsAtTheSelectedMembersFolder() async {
        let chooser = Chooser()
        let store = store(chooser)
        store.selectedID = "b"
        _ = await store.newLane(in: group(store, "Work"), backendID: "agent", focus: false)
        store.selectedID = "c"
        _ = await store.newLane(in: group(store, "Work"), backendID: "agent", focus: false)
        XCTAssertEqual(chooser.openedAt, [URL(fileURLWithPath: "/w/b"), URL(fileURLWithPath: "/w/a")])
    }

    func testTheLaneIsMadeInTheSectionAndSelected() async throws {
        let chooser = Chooser()
        chooser.answer = URL(fileURLWithPath: "/w/new")
        let store = store(chooser)
        let addedResult = await store.newLane(in: group(store, "Work"), backendID: "agent", focus: false)
        let added = try XCTUnwrap(addedResult)
        XCTAssertEqual(store.selectedID, added.id)
        XCTAssertEqual(store.layout.section(of: added.lane), "Work")
        XCTAssertEqual(added.lane.directory?.path, "/w/new")
        XCTAssertTrue(added.lane.isClosable)
        XCTAssertNil(added.lane.variant)
        XCTAssertEqual(group(store, "Work").lanes.map(\.id).last, added.id)
        store.detachAll()
    }

    func testPinnedGroupPinsAndDetachedOffersNothing() async throws {
        let chooser = Chooser()
        chooser.answer = URL(fileURLWithPath: "/w/new")
        let store = store(chooser)
        store.setPinned("c", true)
        let pinned = try XCTUnwrap(store.groups.first(where: \.isPinned))
        let addedResult = await store.newLane(in: pinned, backendID: "agent", focus: false)
        let added = try XCTUnwrap(addedResult)
        XCTAssertTrue(store.layout.pinned.contains(added.id))
        XCTAssertNil(store.layout.section(of: added.lane))
        let detached = LaneGroup(section: LaneLayout.detachedSection, lanes: [], isDetached: true)
        XCTAssertFalse(store.canAddLane(to: detached))
        let none = await store.newLane(in: detached, backendID: "agent", focus: false)
        XCTAssertNil(none)
        store.detachAll()
    }

    func testAReusedFolderGetsASessionOfItsOwn() async throws {
        let wrapper = CommandLaneBackend.tmuxLane(id: "agent", displayName: "Agent", command: "lane-wrapper",
                                                  statusAgent: "claude", variantFlag: "-n")
        let chooser = Chooser()
        chooser.answer = URL(fileURLWithPath: "/w/a")
        let store = store(chooser, backends: [wrapper])
        let firstResult = await store.newLane(in: group(store, "Work"), backendID: "agent", focus: false)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.lane.variant, "2")
        let secondResult = await store.newLane(in: group(store, "Work"), backendID: "agent", focus: false)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(second.lane.variant, "3")
        XCTAssertNotEqual(first.title, second.title)
        store.detachAll()
    }

    func testCollapseOtherSectionsKeepsTheSelectedOnesOpen() {
        let store = store(Chooser())
        store.selectedID = "a"
        XCTAssertTrue(store.canCollapseOtherSections(than: group(store, "Work")))
        store.collapseOtherSectionsThanSelected()
        XCTAssertEqual(store.layout.collapsed, [LaneLayout.unsectionedKey])
        XCTAssertFalse(store.canCollapseOtherSections(than: group(store, "Work")))
        store.setAllCollapsed(true)
        XCTAssertTrue(store.layout.collapsed.contains(LaneLayout.unsectionedKey))
    }
}

@MainActor
final class PinnedNumberTests: XCTestCase {
    private func store() -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false)
        let store = AgentLaneStore(configuration: config,
                                   backends: [CommandLaneBackend(id: "agent", displayName: "Agent", command: "true")],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-pins-\(UUID().uuidString)")!)
        store.sync(lanes: ["a", "b", "c", "d"].map {
            AgentLane(id: $0, title: $0.uppercased(), directory: URL(fileURLWithPath: "/w/" + $0), backendID: "agent", section: "Cloud")
        })
        return store
    }

    func testOnlyPinnedRowsAreNumbered() {
        let store = store()
        XCTAssertTrue(store.numberedLanes.isEmpty, "nothing pinned, nothing numbered")
        store.setPinned("c", true)
        store.setPinned("a", true)
        XCTAssertEqual(store.numberedLanes.map(\.id), ["a", "c"], "pinned rows in the order the list shows them")
        store.open(index: 1)
        XCTAssertEqual(store.selectedID, "c")
        store.open(index: 2)
        XCTAssertEqual(store.selectedID, "c", "a number past the pinned rows goes nowhere")
    }
}
