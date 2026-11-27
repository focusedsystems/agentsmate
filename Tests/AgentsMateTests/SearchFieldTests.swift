import AppKit
import SwiftUI
import XCTest
@testable import AgentsMate

@MainActor
final class SearchFieldTests: XCTestCase {
    private func hosted<V: View>(_ view: V, size: NSSize) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.padding(8).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func snapshot(_ host: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func testTheFieldIsTheSystemSearchField() throws {
        let host = hosted(AgentsSearchField(text: .constant(""), prompt: "Search everything  ⌘K").frame(width: 300),
                          size: NSSize(width: 320, height: 48))
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for sub in view.subviews { if let f = find(sub) { return f } }
            return nil
        }
        let field = try XCTUnwrap(find(host))
        XCTAssertEqual(field.placeholderString, "Search everything  ⌘K")
    }

    func testEachFieldRendersToAPNGWhenAskedTo() throws {
        guard let dir = ProcessInfo.processInfo.environment["SWIFT_AGENTSMATE_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var text = "fleet"
        let cases: [(String, AnyView, NSSize)] = [
            ("toolbar-empty", AnyView(AgentsToolbarSearchField(offscreen: .constant(""), prompt: "Search everything", width: 320)), NSSize(width: 360, height: 56)),
            ("toolbar-typed", AnyView(AgentsToolbarSearchField(offscreen: Binding(get: { text }, set: { text = $0 }), prompt: "Search everything", width: 320)), NSSize(width: 360, height: 56)),
            ("sidebar", AnyView(AgentsSearchField(text: .constant(""), prompt: "Search lanes", controlSize: .small).frame(width: 260)), NSSize(width: 290, height: 40)),
            ("home-filter", AnyView(AgentsSearchField(text: .constant(""), prompt: "Filter", controlSize: .small).frame(width: 200)), NSSize(width: 230, height: 40)),
        ]
        for (name, view, size) in cases {
            let rep = try snapshot(hosted(view, size: size))
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}

@MainActor
final class IconPickerFitTests: XCTestCase {
    func testThePickerFitsItsSheetInLightAndDark() throws {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: LaneIconPicker(icon: .symbol("terminal"), tintHex: nil, laneTitle: "Example",
                                                              onReset: {}, onChoose: { _, _ in }))
            host.appearance = NSAppearance(named: appearance)
            let fitting = host.fittingSize
            XCTAssertEqual(fitting.width, 420, accuracy: 0.5, "\(name): the sheet is one fixed width")
            host.frame = NSRect(origin: .zero, size: fitting)
            host.layoutSubtreeIfNeeded()
            func overflow(_ view: NSView) -> [NSView] {
                var out: [NSView] = []
                for sub in view.subviews {
                    let frame = host.convert(sub.bounds, from: sub)
                    if frame.width > 1, frame.minX < -0.5 || frame.maxX > host.bounds.width + 0.5 { out.append(sub) }
                    out += overflow(sub)
                }
                return out
            }
            XCTAssertTrue(overflow(host).isEmpty, "\(name): \(overflow(host).map { String(describing: type(of: $0)) })")
            if let dir = ProcessInfo.processInfo.environment["SWIFT_AGENTSMATE_RENDER_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon-picker-\(name).png"))
            }
        }
    }
}

@MainActor
final class LaneBadgeRenderTests: XCTestCase {
    func testBadgeStripsRenderWhenAskedTo() throws {
        guard let dir = ProcessInfo.processInfo.environment["SWIFT_AGENTSMATE_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let strips = VStack(alignment: .leading, spacing: 8) {
            LaneBadgeStrip(badges: LaneBadges(hostKind: .local, runKind: .tmux, agent: "claude"))
            LaneBadgeStrip(badges: LaneBadges(hostKind: .remote, hostName: "mac-desktop", runKind: .bg, agent: "codex"))
        }.padding(12).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: strips.scaleEffect(4, anchor: .topLeading).frame(width: 400, height: 200, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("badges.png"))
    }
}
