import XCTest
@testable import AgentsMate

private func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
    // Shift reports the capital, as a real key press does.
    let typed = flags.contains(.shift) ? chars.uppercased() : chars
    return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                            context: nil, characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: code)!
}

final class ReopenShortcutBindingTests: XCTestCase {
    func testDefaultsMatchEveryApp() {
        let expected: [(LaneShortcutAction, String, LaneReopenChoice.Kind)] = [
            (.reopenSameAgent, "⌥⌘R", .sameAgent),
            (.reopenClaudeRemote, "⇧⌘C", .claudeRemote),
            (.reopenCodexRemote, "⇧⌘X", .codexRemote),
            (.reopenClaudeDirect, "⌥⇧⌘C", .claudeDirect),
            (.reopenCodexDirect, "⌥⇧⌘X", .codexDirect),
        ]
        for (action, display, kind) in expected {
            XCTAssertEqual(LaneShortcutBindings().binding(for: action)?.display, display, action.rawValue)
            XCTAssertEqual(action.reopenKind, kind)
            XCTAssertEqual(kind.shortcutAction, action)
            XCTAssertEqual(action.terminalShortcut, .reopen(kind))
        }
        XCTAssertEqual(Set(LaneReopenChoice.Kind.allCases.map(\.shortcutAction)).count, LaneReopenChoice.Kind.allCases.count)
        XCTAssertNil(LaneShortcutAction.reattach.reopenKind)
    }

    func testKeyPressesPickTheirKind() {
        let bindings = LaneShortcutBindings()
        XCTAssertEqual(bindings.reopenKind(for: key("r", code: 15, flags: [.command, .option])), .sameAgent)
        XCTAssertEqual(bindings.reopenKind(for: key("c", code: 8, flags: [.command, .shift])), .claudeRemote)
        XCTAssertEqual(bindings.reopenKind(for: key("x", code: 7, flags: [.command, .shift])), .codexRemote)
        XCTAssertEqual(bindings.reopenKind(for: key("c", code: 8, flags: [.command, .shift, .option])), .claudeDirect)
        XCTAssertEqual(bindings.reopenKind(for: key("x", code: 7, flags: [.command, .shift, .option])), .codexDirect)
        XCTAssertEqual(bindings.terminalShortcut(for: key("c", code: 8, flags: [.command, .shift])), .reopen(.claudeRemote))
        // Copy, Cut and Reattach are not Reopen As.
        XCTAssertNil(bindings.reopenKind(for: key("c", code: 8, flags: .command)))
        XCTAssertNil(bindings.reopenKind(for: key("x", code: 7, flags: .command)))
        XCTAssertNil(bindings.reopenKind(for: key("r", code: 15, flags: [.command, .shift])))
    }

    func testReopenKeysCanBeChanged() {
        var bindings = LaneShortcutBindings()
        bindings.set(LaneKeyBinding("e", command: true, control: true), for: .reopenClaudeRemote)
        XCTAssertNil(bindings.reopenKind(for: key("c", code: 8, flags: [.command, .shift])))
        XCTAssertEqual(bindings.reopenKind(for: key("e", code: 14, flags: [.command, .control])), .claudeRemote)
        XCTAssertEqual(bindings.conflict(for: LaneKeyBinding("x", command: true, shift: true), excluding: .reopenClaudeRemote),
                       .reopenCodexRemote)
        bindings.set(nil, for: .reopenCodexRemote)
        XCTAssertNil(bindings.reopenKind(for: key("x", code: 7, flags: [.command, .shift])))
    }

    func testSavedBindingsSurviveRemovedActions() throws {
        // A binding saved under an action this version no longer has (the old
        // numbered Reopen As keys) is dropped; the others are kept.
        let json = #"{"overrides":["reopenAs1",{"key":"1","command":false,"shift":false,"option":true,"control":true},"clear",{"key":"l","command":true,"shift":false,"option":false,"control":false},"split",null]}"#
        let decoded = try JSONDecoder().decode(LaneShortcutBindings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.binding(for: .clear), LaneKeyBinding("l", command: true))
        XCTAssertNil(decoded.binding(for: .split))
        XCTAssertEqual(decoded.overrides.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(LaneShortcutBindings.self, from: Data("{}".utf8)), LaneShortcutBindings())
    }
}

@MainActor
final class ReopenByKindTests: XCTestCase {
    private func makeStore() -> AgentLaneStore {
        let defaults = UserDefaults(suiteName: "agentsmate-reopen-kind-\(UUID().uuidString)")!
        let backends = ["remote", "codex-remote", "claude", "codex"].map {
            CommandLaneBackend(id: $0, displayName: $0, command: "true")
        }
        let store = AgentLaneStore(configuration: .init(termProgram: "Test", reopenChoices: [
            .sameAgent(),
            LaneReopenChoice("Claude (remote)", backendID: "remote", kind: .claudeRemote),
            LaneReopenChoice("Codex (remote)", backendID: "codex-remote", kind: .codexRemote),
            LaneReopenChoice("Claude (direct)", backendID: "claude", kind: .claudeDirect),
        ]), backends: backends, statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "remote")])
        return store
    }

    func testKindsReopenOnTheirBackend() {
        let store = makeStore()
        store.open("a")
        XCTAssertTrue(store.reopenSelected(kind: .claudeDirect))
        XCTAssertEqual(store.sessions["a"]?.backend.id, "claude")
        XCTAssertTrue(store.reopen("a", kind: .sameAgent))
        XCTAssertEqual(store.sessions["a"]?.backend.id, "claude", "Same Agent keeps the lane's agent")
        XCTAssertFalse(store.reopen("a", kind: .codexDirect), "the app offers no Codex (direct)")
        XCTAssertEqual(store.sessions["a"]?.backend.id, "claude")
        XCTAssertTrue(store.handle(.reopen(.codexRemote), from: "a"))
        XCTAssertEqual(store.sessions["a"]?.backend.id, "codex-remote")
        XCTAssertFalse(store.handle(.reopen(.codexDirect), from: "a"), "an unoffered kind goes on to the app")
        store.detachAll()
    }

    func testMenuShowsTheKeysOnlyWhileTheLanesHaveTheKeyboard() {
        let store = makeStore()
        let remote = store.configuration.reopenChoices[1]
        XCTAssertNil(store.reopenMenuBinding(for: remote), "elsewhere the app keeps ⇧⌘C")
        store.lanesHaveKeyboard = true
        XCTAssertEqual(store.reopenMenuBinding(for: remote)?.display, "⇧⌘C")
        XCTAssertEqual(store.reopenMenuBinding(for: .sameAgent())?.display, "⌥⌘R")
        XCTAssertNil(store.reopenMenuBinding(for: LaneReopenChoice("Other", backendID: "claude")), "no kind, no key")
        store.shortcuts.set(nil, for: .reopenClaudeRemote)
        XCTAssertNil(store.reopenMenuBinding(for: remote))
    }

    func testAStoreWithoutReopenKeysLeavesThem() {
        let defaults = UserDefaults(suiteName: "agentsmate-reopen-off-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "Test", shortcuts: [.clear],
                                                        reopenChoices: [.sameAgent()]),
                                   backends: [CommandLaneBackend(id: "x", displayName: "x", command: "true")],
                                   statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "x")])
        XCTAssertFalse(store.handle(.reopen(.sameAgent), from: "a"))
        XCTAssertTrue(TerminalShortcut.Set.fixedLanes.contains(.reopen))
        XCTAssertTrue(TerminalShortcut.Set.all.contains(.reopen))
    }
}

@MainActor
final class TerminalCopyPasteTests: XCTestCase {
    func testCommandCCopiesTheSelectionWithoutTheMenus() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let board = NSPasteboard(name: NSPasteboard.Name("agentsmate-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        view.pasteboard = board
        view.feed(text: "hello lane")
        XCTAssertFalse(view.handleKeyDown(key("c", code: 8, flags: .command)), "no selection: ⌘C goes on")
        view.selectAll(nil)
        XCTAssertTrue(view.hasSelection)
        XCTAssertTrue(view.handleKeyDown(key("c", code: 8, flags: .command)))
        XCTAssertEqual(board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "hello lane")
        board.clearContents()
        view.copy(self)
        XCTAssertEqual(board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "hello lane",
                       "Edit › Copy copies the same text")
    }

    func testProgramClipboardWritesReachThePasteboard() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let board = NSPasteboard(name: NSPasteboard.Name("agentsmate-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        view.pasteboard = board
        let encoded = Data("from claude".utf8).base64EncodedString()
        let sequence = Array("\u{1b}]52;c;\(encoded)\u{07}".utf8)
        view.dataReceived(slice: sequence[0..<9])
        XCTAssertNil(board.string(forType: .string))
        view.dataReceived(slice: sequence[9...])
        XCTAssertEqual(board.string(forType: .string), "from claude", "the c selection Claude Code sends")

        let tmux = "\u{1b}]52;;\(Data("from tmux".utf8).base64EncodedString())\u{07}"
        view.dataReceived(slice: ArraySlice(Array("\u{1b}Ptmux;\(tmux.replacingOccurrences(of: "\u{1b}", with: "\u{1b}\u{1b}"))\u{1b}\\".utf8)))
        XCTAssertEqual(board.string(forType: .string), "from tmux", "wrapped in tmux passthrough")

        view.dataReceived(slice: ArraySlice(Array("\u{1b}]52;c;?\u{07}".utf8)))
        XCTAssertEqual(board.string(forType: .string), "from tmux", "a read request leaves the clipboard alone")
    }

    func testShiftAtThePressSelectsInTheTerminal() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let press = { (flags: NSEvent.ModifierFlags) in
            NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.selectsOnShift(press(.shift))
        XCTAssertFalse(view.allowMouseReporting, "⇧-drag selects here, not in the program")
        view.selectsOnShift(press([]))
        XCTAssertTrue(view.allowMouseReporting)
    }

    func testCommandVIsTakenByTheTerminal() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let board = NSPasteboard(name: NSPasteboard.Name("agentsmate-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        view.pasteboard = board
        board.clearContents()
        XCTAssertTrue(view.handleKeyDown(key("v", code: 9, flags: .command)), "⌘V is the terminal's even when empty")
        XCTAssertFalse(view.handleKeyDown(key("v", code: 9, flags: [.command, .shift, .option])))
    }

    func testPasteSendsTextFilesOrCtrlVForAnImage() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let board = NSPasteboard(name: NSPasteboard.Name("agentsmate-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        view.pasteboard = board

        board.clearContents()
        XCTAssertNil(view.pasteInput(), "an empty pasteboard sends nothing")

        board.clearContents()
        board.setString("echo hi\nls", forType: .string)
        XCTAssertEqual(view.pasteInput().map { String(decoding: $0, as: UTF8.self) }, "echo hi\nls", "a shell takes text as typed")
        view.feed(text: "\u{1b}[?2004h")
        XCTAssertEqual(view.pasteInput().map { String(decoding: $0, as: UTF8.self) }, "\u{1b}[200~echo hi\nls\u{1b}[201~")

        board.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        board.writeObjects([image])
        XCTAssertEqual(PasteContent(board), .image)
        XCTAssertEqual(view.pasteInput(), [0x16], "an image alone is Ctrl+V, for the agent to read")

        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/Screen Shot.png") as NSURL])
        board.setString("Screen Shot.png", forType: .string)
        XCTAssertEqual(PasteContent(board), .files(["/tmp/Screen Shot.png"]), "copied files win over their names")
        XCTAssertEqual(view.pasteInput().map { String(decoding: $0, as: UTF8.self) },
                       "\u{1b}[200~'/tmp/Screen Shot.png' \u{1b}[201~")
    }

    func testReopenKeysReachTheStoreFromATerminal() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        var asked: TerminalShortcut?
        view.shortcutResolver = { LaneShortcutBindings().terminalShortcut(for: $0) }
        view.onShortcut = { asked = $0; return true }
        XCTAssertTrue(view.handleKeyDown(key("x", code: 7, flags: [.command, .shift])))
        XCTAssertEqual(asked, .reopen(.codexRemote))
        asked = nil
        XCTAssertFalse(view.handleKeyDown(key("k", code: 40, flags: .command)), "other shortcuts keep their menu route")
        XCTAssertNil(asked)
    }
}
