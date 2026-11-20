import XCTest
import SwiftTerm
@testable import AgentsMate

final class TerminalLinkTests: XCTestCase {
    private func detect(_ row: String, column: Int) -> String? {
        TerminalLinks.detectedURL(in: Array(row), at: column)?.absoluteString
    }

    func testFindsAPlainURLAroundTheClick() {
        let row = "See https://example.com/pulls/12 for details"
        XCTAssertEqual(detect(row, column: 4), "https://example.com/pulls/12")
        XCTAssertEqual(detect(row, column: 20), "https://example.com/pulls/12")
        XCTAssertEqual(detect(row, column: 31), "https://example.com/pulls/12")
        XCTAssertNil(detect(row, column: 32))
        XCTAssertNil(detect(row, column: 1))
    }

    func testAcceptsHTTPAndIgnoresCase() {
        XCTAssertEqual(detect("HTTP://example.com/a", column: 8), "HTTP://example.com/a")
        XCTAssertEqual(detect("http://localhost:8080/x?y=1#z", column: 0), "http://localhost:8080/x?y=1#z")
    }

    func testDropsTrailingPunctuationAndUnopenedBrackets() {
        XCTAssertEqual(detect("Open https://example.com/a.", column: 10), "https://example.com/a")
        XCTAssertEqual(detect("(see https://example.com/a), then", column: 10), "https://example.com/a")
        XCTAssertEqual(detect("https://en.example.org/wiki/Foo_(bar))", column: 3), "https://en.example.org/wiki/Foo_(bar)")
        XCTAssertEqual(detect("[link](https://example.com/b)", column: 12), "https://example.com/b")
        XCTAssertEqual(detect("<https://example.com/c>", column: 5), "https://example.com/c")
        XCTAssertEqual(detect("\"https://example.com/d\"", column: 5), "https://example.com/d")
    }

    func testClickOnTrimmedPunctuationIsNotALink() {
        let row = "at https://example.com/a."
        XCTAssertNil(detect(row, column: row.count - 1))
    }

    func testRequiresAnExplicitSchemeAndHost() {
        XCTAssertNil(detect("example.com/a", column: 3))
        XCTAssertNil(detect("www.example.com", column: 3))
        XCTAssertNil(detect("https:// nothing", column: 2))
        XCTAssertNil(detect("ftp://example.com/a", column: 8))
        XCTAssertNil(detect("file:///etc/hosts", column: 8))
        XCTAssertNil(detect("", column: 0))
        XCTAssertNil(detect("abc", column: 9))
    }

    func testPicksTheURLUnderTheClickWhenTwoTouch() {
        let row = "https://a.example/x,https://b.example/y"
        XCTAssertEqual(detect(row, column: 2), "https://a.example/x")
        XCTAssertEqual(detect(row, column: 25), "https://b.example/y")
    }

    func testStopsAtNonASCII() {
        XCTAssertEqual(detect("→https://example.com/a→", column: 4), "https://example.com/a")
    }

    func testReadsOSC8Payloads() {
        XCTAssertEqual(TerminalLinks.hyperlinkURL(fromPayload: ";https://example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(TerminalLinks.hyperlinkURL(fromPayload: "id=7;https://example.com/a;b")?.absoluteString, "https://example.com/a;b")
        XCTAssertEqual(TerminalLinks.hyperlinkURL(fromPayload: ";file:///tmp/x.txt")?.scheme, "file")
        XCTAssertNotNil(TerminalLinks.hyperlinkURL(fromPayload: ";https://example.com/a b"))
        XCTAssertNil(TerminalLinks.hyperlinkURL(fromPayload: "https://example.com"))
        XCTAssertNil(TerminalLinks.hyperlinkURL(fromPayload: ";"))
        XCTAssertNil(TerminalLinks.hyperlinkURL(fromPayload: ";no scheme here"))
    }

    func testOnlyWebAndMailLinksOpenInTheSystem() {
        func opens(_ string: String) -> Bool { TerminalLinks.opensInSystem(URL(string: string)!) }
        XCTAssertTrue(opens("https://example.com"))
        XCTAssertTrue(opens("HTTP://example.com/a"))
        XCTAssertTrue(opens("mailto:someone@example.com"))
        XCTAssertFalse(opens("https:///nohost"))
        XCTAssertFalse(opens("file:///etc/hosts"))
        XCTAssertFalse(opens("ssh://example.com"))
        XCTAssertFalse(opens("x-custom-app://open"))
        XCTAssertFalse(opens("javascript:alert(1)"))
    }

    @MainActor
    func testUnhandledLinksFallBackOnlyForSystemSchemes() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var hooked: [String] = [], opened: [String] = []
        view.openInSystem = { opened.append($0.absoluteString) }
        view.onOpenLink = { hooked.append($0.absoluteString); return $0.host == "handled.example" }
        for link in ["file:///tmp/x", "x-custom://open", "https://handled.example/a", "https://example.com/b", "mailto:a@example.com"] {
            view.openLink(URL(string: link)!)
        }
        XCTAssertEqual(hooked.count, 5)
        XCTAssertEqual(opened, ["https://example.com/b", "mailto:a@example.com"])
    }

    /// SwiftTerm's own opener (an OSC 8 link on a ⌘-release) asks its
    /// terminal delegate; it must reach the hook and the scheme check, never
    /// NSWorkspace directly.
    @MainActor
    func testSwiftTermLinkRequestsGoThroughTheSchemeCheck() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var hooked: [String] = [], opened: [String] = []
        view.openInSystem = { opened.append($0.absoluteString) }
        view.onOpenLink = { hooked.append($0.absoluteString); return false }
        guard let delegate = view.terminalDelegate else { return XCTFail("no terminal delegate") }
        XCTAssertFalse(delegate === view)
        for link in ["file:///etc/hosts", "x-custom://open", "javascript:alert(1)", "https://example.com/a"] {
            delegate.requestOpenLink(source: view, link: link, params: [:])
        }
        XCTAssertEqual(hooked, ["file:///etc/hosts", "x-custom://open", "javascript:alert(1)", "https://example.com/a"])
        XCTAssertEqual(opened, ["https://example.com/a"])

        view.onOpenLink = nil
        opened = []
        delegate.requestOpenLink(source: view, link: "file:///etc/hosts", params: [:])
        XCTAssertEqual(opened, [])
    }

    @MainActor
    func testTerminalDelegateStillDrivesTheProcess() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let title = TitleRecorder()
        view.processDelegate = title
        view.terminalDelegate?.setTerminalTitle(source: view, title: "lane")
        XCTAssertEqual(title.titles, ["lane"])
    }

    @MainActor
    func testFindsLinksInTheBuffer() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.feed(text: "go to https://example.com/a now\r\n")
        view.feed(text: "\u{1b}]8;;https://example.com/osc\u{1b}\\label\u{1b}]8;;\u{1b}\\ plain\r\n")
        XCTAssertEqual(view.link(atColumn: 8, row: 0)?.absoluteString, "https://example.com/a")
        XCTAssertNil(view.link(atColumn: 2, row: 0))
        XCTAssertEqual(view.link(atColumn: 2, row: 1)?.absoluteString, "https://example.com/osc")
        XCTAssertNil(view.link(atColumn: 7, row: 1))
    }
}

@MainActor
private final class TitleRecorder: LocalProcessTerminalViewDelegate {
    var titles: [String] = []
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated { titles.append(title) }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
