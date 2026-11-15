import XCTest
@testable import AgentsMate

final class ShortcutBindingTests: XCTestCase {
    private func key(_ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testDefaultsAndOverrides() {
        var bindings = LaneShortcutBindings()
        XCTAssertEqual(bindings.terminalShortcut(for: key("k", code: 40, flags: .command)), .clear)
        XCTAssertEqual(bindings.terminalShortcut(for: key("}", code: 30, flags: [.command, .shift])), .next)
        XCTAssertEqual(bindings.terminalShortcut(for: key("3", code: 20, flags: .command)), .select(2))
        bindings.set(LaneKeyBinding("l", command: true), for: .clear)
        XCTAssertNil(bindings.terminalShortcut(for: key("k", code: 40, flags: .command)))
        XCTAssertEqual(bindings.terminalShortcut(for: key("l", code: 37, flags: .command)), .clear)
        XCTAssertEqual(bindings.conflict(for: LaneKeyBinding("t", command: true), excluding: .clear), .newLane)
        bindings.set(nil, for: .split)
        XCTAssertNil(bindings.binding(for: .split))
        bindings.set(LaneShortcutBindings.defaults[.clear], for: .clear)
        XCTAssertNil(bindings.overrides[.clear], "setting a default back removes the override")
    }

    func testPlainKeysAreNotShortcuts() {
        XCTAssertNil(LaneKeyBinding(event: key("a", code: 0, flags: [])))
        XCTAssertNil(LaneKeyBinding(event: key("A", code: 0, flags: .shift)))
        XCTAssertEqual(LaneKeyBinding(event: key("\u{1b}[D", code: 123, flags: [.command, .option]))?.key, "left")
    }

    func testRoundTripAndDisplay() throws {
        var bindings = LaneShortcutBindings()
        bindings.set(LaneKeyBinding("return", command: true, shift: true), for: .goToLane)
        bindings.set(nil, for: .split)
        let decoded = try JSONDecoder().decode(LaneShortcutBindings.self, from: JSONEncoder().encode(bindings))
        XCTAssertEqual(decoded, bindings)
        XCTAssertEqual(LaneKeyBinding("return", command: true, shift: true).display, "⇧⌘↩")
    }
}
