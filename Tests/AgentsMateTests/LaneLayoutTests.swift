import XCTest
@testable import AgentsMate

final class LaneLayoutTests: XCTestCase {
    private func lane(_ id: String, section: String? = nil) -> AgentLane {
        AgentLane(id: id, title: id, backendID: "s", section: section)
    }

    func testGroupsPinnedLooseThenSections() {
        let lanes = [lane("a"), lane("b", section: "Work"), lane("c", section: "Home"), lane("d")]
        var layout = LaneLayout()
        layout.setPinned("d", true)
        let groups = layout.groups(for: lanes) { _ in nil }
        XCTAssertEqual(groups.map(\.section), ["Pinned", nil, "Work", "Home"])
        XCTAssertEqual(groups.map { $0.lanes.map(\.id) }, [["d"], ["a"], ["b"], ["c"]])
    }

    func testMoveRenameAndRemoveSections() {
        let lanes = [lane("a"), lane("b", section: "Work")]
        var layout = LaneLayout()
        layout.move("a", to: "Work")
        XCTAssertEqual(layout.section(of: lanes[0]), "Work")
        layout.renameSection("Work", to: "Jobs", lanes: lanes)
        XCTAssertEqual(layout.section(of: lanes[1]), "Jobs")
        layout.removeSection("Jobs", lanes: lanes)
        XCTAssertNil(layout.section(of: lanes[0]))
        XCTAssertNil(layout.section(of: lanes[1]))
    }

    func testEmptySectionThePersonMadeStillShows() {
        var layout = LaneLayout()
        layout.addSection("Later")
        XCTAssertEqual(layout.groups(for: [lane("a")]) { _ in nil }.map(\.section), [nil, "Later"])
    }

    func testManualOrderAndRecencySorts() {
        let lanes = [lane("a"), lane("b"), lane("c")]
        var layout = LaneLayout()
        layout.moveLane("c", before: "a", lanes: lanes)
        XCTAssertEqual(layout.groups(for: lanes) { _ in nil }.first?.lanes.map(\.id), ["c", "a", "b"])
        let times = ["a": Date(timeIntervalSince1970: 30), "b": Date(timeIntervalSince1970: 20)]
        layout.sort = .recentFirst
        XCTAssertEqual(layout.groups(for: lanes) { times[$0.id] }.first?.lanes.map(\.id), ["a", "b", "c"])
        layout.sort = .recentLast
        XCTAssertEqual(layout.groups(for: lanes) { times[$0.id] }.first?.lanes.map(\.id), ["c", "b", "a"])
    }

    func testMoveSectionReorders() {
        let lanes = [lane("a", section: "One"), lane("b", section: "Two")]
        var layout = LaneLayout()
        layout.moveSection("Two", by: -1, lanes: lanes)
        XCTAssertEqual(layout.orderedSections(for: lanes), ["Two", "One"])
    }
}

@MainActor
final class StoreLayoutTests: XCTestCase {
    func testNumbersFollowDisplayOrderAndLayoutIsSaved() {
        let defaults = UserDefaults(suiteName: "agentsmate-layout-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "T"), backends: [CommandLaneBackend.shell],
                                   statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "shell"),
                           AgentLane(id: "b", title: "B", backendID: "shell")])
        store.setPinned("b", true)
        XCTAssertEqual(store.displayOrder.map(\.id), ["b", "a"])
        let reloaded = AgentLaneStore(configuration: .init(termProgram: "T"), backends: [CommandLaneBackend.shell],
                                      statusFeed: nil, defaults: defaults)
        XCTAssertEqual(reloaded.layout.pinned, ["b"])
    }
}
