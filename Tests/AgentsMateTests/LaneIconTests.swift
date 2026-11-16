import XCTest
import SwiftUI
@testable import AgentsMate

@MainActor
final class LaneIconTests: XCTestCase {
    func testParsingTheStringForms() {
        XCTAssertEqual(LaneIcon("sf:hammer"), .symbol("hammer"))
        XCTAssertEqual(LaneIcon("svg:rocket"), .bundled("rocket"))
        XCTAssertEqual(LaneIcon("terminal"), .symbol("terminal"))
        XCTAssertEqual(LaneIcon("  sf:star.fill "), .symbol("star.fill"))
        XCTAssertNil(LaneIcon(""))
        XCTAssertNil(LaneIcon("sf:"))
        XCTAssertNil(LaneIcon("svg:  "))
        XCTAssertNil(LaneIcon("other:thing"))
    }

    func testStringAndCodableRoundTrip() throws {
        for icon in [LaneIcon.symbol("hammer"), .bundled("rocket"), .symbol("arrow.triangle.branch")] {
            XCTAssertEqual(LaneIcon(icon.stringValue), icon)
            let data = try JSONEncoder().encode([icon])
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"\(icon.stringValue)\"]")
            XCTAssertEqual(try JSONDecoder().decode([LaneIcon].self, from: data), [icon])
        }
        XCTAssertThrowsError(try JSONDecoder().decode([LaneIcon].self, from: Data("[\"x:y\"]".utf8)))
    }

    func testLaneIconWinsOverSymbol() {
        var lane = AgentLane(id: "a", title: "a", symbol: "folder", backendID: "s")
        XCTAssertEqual(lane.resolvedIcon, .symbol("folder"))
        lane.icon = .bundled("rocket")
        XCTAssertEqual(lane.resolvedIcon, .bundled("rocket"))
    }

    func testOldLayoutDecodesWithNoIcons() throws {
        let old = #"{"sections":["Work"],"pinned":["a"],"names":{"a":"Alpha"},"sort":"manual"}"#
        let layout = try JSONDecoder().decode(LaneLayout.self, from: Data(old.utf8))
        XCTAssertEqual(layout.sections, ["Work"])
        XCTAssertEqual(layout.names["a"], "Alpha")
        XCTAssertTrue(layout.icons.isEmpty)
        XCTAssertTrue(layout.tints.isEmpty)
    }

    func testLayoutKeepsIconsThroughEncoding() throws {
        var layout = LaneLayout()
        layout.setIcon(.bundled("rocket"), tint: "#e5484d", for: "a")
        XCTAssertEqual(layout.icons["a"], "svg:rocket")
        XCTAssertEqual(layout.tints["a"], "#E5484D")
        let back = try JSONDecoder().decode(LaneLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(back, layout)
        layout.setIcon(nil, tint: "not a colour", for: "a")
        XCTAssertNil(layout.icons["a"])
        XCTAssertNil(layout.tints["a"])
    }

    func testStoreSetIconPersistsAndNotifies() throws {
        let suite = "LaneIconTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lane = AgentLane(id: "a", title: "a", symbol: "folder", tintHex: "#0A84FF", backendID: "shell")
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil), backends: [], statusFeed: nil, defaults: defaults)
        store.sync(lanes: [lane])
        var told: [(String, String?, String?)] = []
        store.onIconChange = { lane, icon, tint in told.append((lane.id, icon?.stringValue, tint)) }

        let session = try XCTUnwrap(store.session(for: lane))
        XCTAssertEqual(session.icon, .symbol("folder"))
        XCTAssertEqual(session.tintHex, "#0A84FF")

        store.setIcon(.bundled("rocket"), tint: "#30A46C", for: "a")
        XCTAssertEqual(session.icon, .bundled("rocket"))
        XCTAssertEqual(session.tintHex, "#30A46C")
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told.first?.1, "svg:rocket")

        let again = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil), backends: [], statusFeed: nil, defaults: defaults)
        again.sync(lanes: [lane])
        XCTAssertEqual(again.session(for: lane)?.icon, .bundled("rocket"))

        store.sync(lanes: [lane])
        XCTAssertEqual(session.icon, .bundled("rocket"))

        store.setIcon(nil, tint: nil, for: "a")
        XCTAssertEqual(session.icon, .symbol("folder"))
        XCTAssertEqual(session.tintHex, "#0A84FF")
    }

    func testEveryCuratedBundledIconExistsAndLoads() {
        let names = LaneIconLibrary.bundledNames
        XCTAssertGreaterThanOrEqual(names.count, 150)
        XCTAssertEqual(Set(names).count, names.count, "duplicate names")
        for name in names {
            XCTAssertTrue(LaneIconLibrary.hasBundled(name), "missing \(name).svg")
            let image = LaneIconLibrary.bundledImage(name)
            XCTAssertNotNil(image, "\(name).svg does not load")
            XCTAssertEqual(image?.isTemplate, true)
        }
        XCTAssertNil(LaneIconLibrary.bundledImage("../LICENSE"))
        XCTAssertNil(LaneIconLibrary.bundledImage("no-such-icon"))
    }

    func testEverySymbolExistsOnThisMac() {
        let names = LaneIconLibrary.symbolNames
        XCTAssertGreaterThanOrEqual(names.count, 250)
        XCTAssertEqual(Set(names).count, names.count)
        let missing = names.filter { LaneIconLibrary.symbolImage($0) == nil }
        XCTAssertEqual(missing, [])
    }

    func testLicenceShipsWithTheIcons() {
        XCTAssertNotNil(LaneIconLibrary.licenceURL)
    }
}
