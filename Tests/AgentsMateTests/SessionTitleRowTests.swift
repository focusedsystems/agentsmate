import XCTest
import SwiftUI
import SwiftTerm
@testable import AgentsMate
@testable import AgentsMateStatus

@MainActor
final class SessionTitleRowTests: XCTestCase {
    private func store(baseFontSize: CGFloat? = nil) -> AgentLaneStore {
        let defaults = UserDefaults(suiteName: "agentsmate-title-\(UUID().uuidString)")!
        var configuration = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                         sharedLanes: nil, liveSnapshotFile: nil)
        if let baseFontSize { configuration.baseFontSize = baseFontSize }
        return AgentLaneStore(configuration: configuration, backends: [CommandLaneBackend.shell], statusFeed: nil,
                              defaults: defaults)
    }

    private func png(of view: NSView, named name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let dir = ProcessInfo.processInfo.environment["AGENTSMATE_RENDER_DIR"],
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func testTheRowShowsTheTitleWithoutItsRepeatedName() {
        let lane = AgentLane(id: "l", title: "Billing", directory: URL(fileURLWithPath: "/tmp"), backendID: "shell")
        let session = AgentLaneSession(lane: lane, backend: CommandLaneBackend.shell)
        XCTAssertNil(session.subtitle)
        session.update(sessionTitle: "Billing · Quarterly Review")
        XCTAssertEqual(session.subtitle, "Quarterly Review")
        XCTAssertEqual(session.title, "Billing", "the row's own name never changes")
        session.update(sessionTitle: "Billing")
        XCTAssertNil(session.subtitle)
    }

    func testTerminalsStartOneStepLargerAndResetThere() {
        let app = store(baseFontSize: 12)
        XCTAssertEqual(app.fontSize, 13)
        app.adjustFont(by: 2)
        XCTAssertEqual(app.fontSize, 15)
        app.adjustFont(by: -1)
        XCTAssertEqual(app.fontSize, 14)
        app.resetFont()
        XCTAssertEqual(app.fontSize, 13)
        XCTAssertEqual(app.fontOffset, 0)
        XCTAssertEqual(store().fontSize, NSFont.systemFontSize + AgentLaneStore.defaultFontStep)
    }

    func testRenderTheRowAndTheTerminal() throws {
        let appStore = store(baseFontSize: 12)
        let lane = AgentLane(id: "l", title: "Billing", directory: URL(fileURLWithPath: "/tmp/Billing"), backendID: "shell")
        let session = AgentLaneSession(lane: lane, backend: CommandLaneBackend.shell)
        session.update(sessionTitle: "Billing · Quarterly Review")
        session.summary = "Weekly sync: invoices reviewed, exports and retries up for discussion"
        XCTAssertEqual(session.subtitle, "Quarterly Review")
        for scheme in [ColorScheme.light, .dark] {
            let row = LaneRow(session: session, shortcutNumber: nil, isSplit: false)
                .padding(8).frame(width: 300, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: row)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            try png(of: host, named: "session-title-row-\(scheme == .dark ? "dark" : "light").png")
        }
        let terminal = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 560, height: 120))
        terminal.font = appStore.font
        XCTAssertEqual(terminal.font.pointSize, 13)
        terminal.feed(text: "$ codex\r\nSession title shown under the row name\r\nterminal text at \(Int(appStore.fontSize)) pt (was 12 pt)\r\n")
        try png(of: terminal, named: "terminal-default-size.png")
    }
}
