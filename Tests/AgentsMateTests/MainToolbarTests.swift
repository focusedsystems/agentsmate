import SwiftUI
import XCTest
@testable import AgentsMate

@MainActor
final class MainToolbarTests: XCTestCase {
    private func strip(width: CGFloat, selected: String, agentOn: Bool) -> some View {
        let tabs = ["Development", "Projects", "Inventory", "Identity", "Tenant", "Servers", "Network"].map {
            CollapsingTab(id: $0, title: $0, systemImage: "circle")
        }
        return AgentsToolbarStrip(agent: AgentsToolbarAgent(isOn: agentOn) {}, tabs: tabs, selection: selected,
                                  width: width, search: ("Search everything", "⌘K")) { EmptyView() }
    }

    func testTheStripDrawsAtTheWindowsWidthWithAndWithoutAgentsMode() throws {
        for on in [false, true] {
            let renderer = ImageRenderer(content: strip(width: 1400, selected: "Projects", agentOn: on))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertEqual(image.size.width, 1400)
            XCTAssertEqual(image.size.height, 52)
        }
    }

    func testTheSearchFieldWidthNarrowsWithTheWindow() {
        XCTAssertEqual(AgentsToolbar.searchWidth(forWindow: 1199), 240)
        XCTAssertEqual(AgentsToolbar.searchWidth(forWindow: 1200), 320)
    }

    func testTheAgentSymbolIsOneThePlatformHas() {
        XCTAssertNotNil(NSImage(systemSymbolName: AgentsToolbar.agentSymbol, accessibilityDescription: nil))
    }

    func testTheAgentButtonSaysWhatItDoes() {
        XCTAssertTrue(AgentsToolbarAgent(isOn: true) {}.help.hasPrefix("Hide"))
        XCTAssertTrue(AgentsToolbarAgent(isOn: false) {}.help.hasPrefix("Work with"))
    }
}
