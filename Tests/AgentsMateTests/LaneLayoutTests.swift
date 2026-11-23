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

    func testEmptySectionThePersonMadeIsLeftOutOfTheList() {
        var layout = LaneLayout()
        layout.addSection("Later")
        XCTAssertEqual(layout.groups(for: [lane("a")]) { _ in nil }.map(\.section), [nil])
        XCTAssertEqual(layout.sections, ["Later"])
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

final class LaneNamingTests: XCTestCase {
    func testTitleTaskStripsGlyphsAndIgnoresShellTitles() {
        XCTAssertEqual(TerminalTitle.task(from: "⠋ Fix the login bug"), "Fix the login bug")
        XCTAssertEqual(TerminalTitle.task(from: "✳ Review PR"), "Review PR")
        XCTAssertNil(TerminalTitle.task(from: "rod@mac: ~/src"))
        XCTAssertNil(TerminalTitle.task(from: "zsh"))
        XCTAssertNil(TerminalTitle.task(from: "✳"))
    }

    func testCopyNames() {
        XCTAssertEqual("Docs".nextCopyName(taken: []), "Docs 2")
        XCTAssertEqual("Docs 2".nextCopyName(taken: ["Docs 3"]), "Docs 4")
    }

    func testMetadataIsTidied() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meta-\(UUID().uuidString).json")
        try Data(#"{"title":"  Ship \u001b[31mit  ","section":""}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let meta = try XCTUnwrap(LaneSessionMetadata.read(url))
        XCTAssertEqual(meta.title, "Ship [31mit")
        XCTAssertNil(meta.section)
    }
}

@MainActor
final class DuplicateSwitchTests: XCTestCase {
    func testDuplicateAndSwitchKeepPlaceAndName() {
        let defaults = UserDefaults(suiteName: "agentsmate-dup-\(UUID().uuidString)")!
        let other = CommandLaneBackend(id: "other", displayName: "Other", command: "true")
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell, other], statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "shell", section: "Work"),
                           AgentLane(id: "b", title: "B", backendID: "shell")])
        let copy = store.duplicate("a", focus: false)
        XCTAssertEqual(copy?.title, "A 2")
        XCTAssertEqual(store.displayOrder.map { store.sessions[$0.id]!.title }, ["B", "A", "A 2"])
        XCTAssertEqual(store.layout.section(of: copy!.lane), "Work")
        store.switchBackend(copy!.id, to: "other")
        XCTAssertEqual(store.lanes.first { $0.id == copy!.id }?.backendID, "other")
        XCTAssertEqual(store.sessions[copy!.id]?.title, "A 2")
        store.rename("a", to: "Alpha")
        XCTAssertEqual(store.sessions["a"]?.title, "Alpha")
        store.rename("a", to: "")
        XCTAssertEqual(store.sessions["a"]?.title, "A")
    }
}
