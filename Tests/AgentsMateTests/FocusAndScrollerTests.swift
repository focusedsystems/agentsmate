import XCTest
import AppKit
@testable import AgentsMate

@MainActor
final class FocusAndScrollerTests: XCTestCase {
    private func host() -> (NSWindow, AgentLaneSession, TerminalContainer) {
        let session = AgentLaneSession(lane: AgentLane(id: "f", title: "F", backendID: "x"),
                                       backend: CommandLaneBackend(id: "x", displayName: "X", command: "true"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let container = TerminalContainer()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        container.session = session
        window.contentView?.addSubview(container)
        session.view.frame = container.bounds
        container.addSubview(session.view)
        return (window, session, container)
    }

    func testBecomingKeyGivesTheTerminalTheKeyboard() {
        let (window, session, _) = host()
        XCTAssertFalse(window.firstResponder === session.view)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(window.firstResponder === session.view)
    }

    func testAnotherPaneThatHadFocusGetsItBack() {
        let (window, session, container) = host()
        let other = FocusableView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        window.contentView?.addSubview(other)
        window.makeFirstResponder(other)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.makeFirstResponder(nil)
        container.restoreFocus()
        XCTAssertTrue(window.firstResponder === other)
        XCTAssertFalse(window.firstResponder === session.view)
    }

    func testTheScrollerIsHiddenAndItsStripClipped() {
        let (window, session, container) = host()
        session.view.frame = NSRect(x: 0, y: 0, width: 600 + AgentTerminalView.hiddenScrollerWidth, height: 400)
        session.view.layoutSubtreeIfNeeded()
        session.view.hideScroller()
        let scrollers = session.view.subviews.compactMap { $0 as? NSScroller }
        XCTAssertFalse(scrollers.isEmpty)
        XCTAssertTrue(scrollers.allSatisfy(\.isHidden))
        XCTAssertTrue(container.layer?.masksToBounds ?? false)
        _ = window
    }
}

extension FocusAndScrollerTests {
    private func render(_ view: NSView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func distinctColours(in rep: NSBitmapImageRep, strip: NSRect) -> Int {
        var seen = Set<[CGFloat]>()
        for x in Int(strip.minX)..<Int(strip.maxX) {
            for y in Int(strip.minY)..<Int(strip.maxY) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert([(c.redComponent * 50).rounded(), (c.greenComponent * 50).rounded(), (c.blueComponent * 50).rounded()])
            }
        }
        return seen.count
    }

    func testTheRightEdgeDrawsNoScrollerTrack() throws {
        let (window, session, container) = host()
        session.view.frame = NSRect(x: 0, y: 0, width: 600 + AgentTerminalView.hiddenScrollerWidth, height: 400)
        window.contentView?.layoutSubtreeIfNeeded()
        let strip = NSRect(x: 600 - 15, y: 0, width: 15, height: 400)
        // Before: the terminal flush with the pane and its scroller showing.
        container.layer?.masksToBounds = false
        session.view.frame = container.bounds
        session.view.layoutSubtreeIfNeeded()
        session.view.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = false }
        let before = render(container)
        // After: scroller hidden and its strip pushed out and clipped.
        container.layer?.masksToBounds = true
        session.view.frame = NSRect(x: 0, y: 0, width: 600 + AgentTerminalView.hiddenScrollerWidth, height: 400)
        session.view.layoutSubtreeIfNeeded()
        session.view.hideScroller()
        let after = render(container)
        XCTAssertEqual(distinctColours(in: after, strip: strip), 1)
        let dir = ProcessInfo.processInfo.environment["AGENTSMATE_RENDER_DIR"]
        if let dir {
            for (name, rep) in [("scroller-before", before), ("scroller-after", after)] {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
