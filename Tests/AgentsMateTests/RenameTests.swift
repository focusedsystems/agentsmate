import XCTest
@testable import AgentsMate
import AgentsMateStatus
import SwiftTerm

final class PromptLineTests: XCTestCase {
    /// A screen row from text; characters at `dim` offsets are drawn dim.
    private func row(_ text: String, width: Int = 40, dim: Range<Int>? = nil) -> [AgentPromptLine.Cell] {
        var cells = text.enumerated().map { offset, character in
            AgentPromptLine.Cell(character, dim: dim?.contains(offset) ?? false)
        }
        while cells.count < width { cells.append(.init(" ")) }
        return cells
    }

    private let rule = String(repeating: "─", count: 40)

    private func read(_ above: String?, _ line: String, _ below: String?, cursor: Int,
                      dim: Range<Int>? = nil) -> AgentPromptLine.Reading {
        AgentPromptLine.read(above: above.map { row($0) }, row: row(line, dim: dim),
                             below: below.map { row($0) }, cursorColumn: cursor)
    }

    func testClaudeEmptyPromptBetweenRules() {
        XCTAssertEqual(read(rule, "❯ ", rule, cursor: 2), .empty)
        // Claude draws a no-break space after the marker.
        XCTAssertEqual(read(rule, "❯\u{00A0}", rule, cursor: 2), .empty)
        // The rule above can carry the session's name.
        XCTAssertEqual(read("────── my-lane ─", "❯ ", rule, cursor: 2), .empty)
    }

    func testDimPlaceholderCountsAsEmpty() {
        XCTAssertEqual(read(rule, "❯ Try \"fix the build\"", rule, cursor: 2, dim: 2..<21), .empty)
        XCTAssertEqual(read("", "› Ask Codex to do anything", "", cursor: 2, dim: 2..<26), .empty)
    }

    func testTypedTextIsNotEmpty() {
        XCTAssertEqual(read(rule, "❯ hello there", rule, cursor: 13), .typed)
        // The cursor moved back to the start of what was typed.
        XCTAssertEqual(read(rule, "❯ hello there", rule, cursor: 2), .typed)
        XCTAssertEqual(read("", "› fix it", "", cursor: 8), .typed)
        // Typed text after a dim placeholder is still text.
        XCTAssertEqual(read(rule, "❯ a", rule, cursor: 3), .typed)
    }

    func testOldClaudeBox() {
        let top = "╭" + String(repeating: "─", count: 20) + "╮"
        let bottom = "╰" + String(repeating: "─", count: 20) + "╯"
        XCTAssertEqual(read(top, "│ >                   │", bottom, cursor: 4), .empty)
        XCTAssertEqual(read(top, "│ > half a prompt     │", bottom, cursor: 17), .typed)
    }

    func testMultiLineBox() {
        let top = "╭" + String(repeating: "─", count: 20) + "╮"
        // The cursor on the first, empty line with a second line below it.
        XCTAssertEqual(read(top, "│ >                   │", "│   second line       │", cursor: 4), .typed)
        XCTAssertEqual(read(rule, "❯ ", "  second line", cursor: 2), .typed)
        // The cursor on a later line: no marker on its row.
        XCTAssertEqual(read("│ > first line        │", "│   second line       │", "╰───╯", cursor: 15), .unknown)
        // A line that starts with ">" inside a longer prompt.
        XCTAssertEqual(read("› first line", "  > quoted", "", cursor: 4), .unknown)
    }

    func testUnknownLayoutsDoNotSend() {
        // No marker.
        XCTAssertEqual(read(rule, "$ ", rule, cursor: 2), .unknown)
        XCTAssertEqual(read(rule, "Thinking…", rule, cursor: 0), .unknown)
        // A marker, but the cursor is elsewhere.
        XCTAssertEqual(read(rule, "❯ ", rule, cursor: 10), .unknown)
        // Text above the prompt that is not a rule or a blank line.
        XCTAssertEqual(read("some output", "❯ ", rule, cursor: 2), .unknown)
        // The prompt at the edge of the screen.
        XCTAssertEqual(read(nil, "❯ ", rule, cursor: 2), .unknown)
        XCTAssertEqual(read(rule, "❯ ", nil, cursor: 2), .unknown)
        // A marker with no space after it.
        XCTAssertEqual(read(rule, "❯x", rule, cursor: 1), .unknown)
        // A dim marker is decoration, not the prompt.
        XCTAssertEqual(read(rule, "❯ ", rule, cursor: 2, dim: 0..<1), .unknown)
        // Too far in to be the input line.
        XCTAssertEqual(read(rule, "      ❯ ", rule, cursor: 8), .unknown)
    }

    func testMenusAreNotEmptyPrompts() {
        // Claude's trust and permission dialogs use the same marker.
        XCTAssertEqual(read("", " ❯ No, exit", "   Yes, I trust this folder", cursor: 0), .typed)
        XCTAssertEqual(read("", "❯ 1. Yes", "  2. No", cursor: 2), .typed)
    }
}

final class AgentRenameTests: XCTestCase {
    private func decide(command: String? = "/rename x", enabled: Bool = true, attached: Bool = true,
                        foreground: Bool = true, state: LaneState? = .done,
                        input: AgentPromptLine.Reading = .empty, readsInput: XCTestExpectation? = nil) -> AgentRenameOutcome {
        AgentRenameOutcome.decide(command: command, enabled: enabled, attached: attached, agentInForeground: foreground,
                                  state: state, input: { readsInput?.fulfill(); return input })
    }

    func testSendsOnlyWhenEverythingAllows() {
        XCTAssertEqual(decide(), .sent)
        XCTAssertEqual(decide(state: nil), .sent)
        XCTAssertEqual(decide(state: .waitingForInput), .sent)
    }

    func testGates() {
        XCTAssertEqual(decide(command: nil), .notSupported)
        XCTAssertEqual(decide(enabled: false), .disabled)
        XCTAssertEqual(decide(attached: false), .notAttached)
        XCTAssertEqual(decide(foreground: false), .agentNotInForeground)
        XCTAssertEqual(decide(state: .running), .busy)
        XCTAssertEqual(decide(state: .permissionRequested), .askingPermission)
        XCTAssertEqual(decide(input: .typed), .inputNotEmpty)
        XCTAssertEqual(decide(input: .unknown), .inputUnknown)
    }

    func testInputIsReadOnlyWhenNothingElseStopsTheSend() {
        let never = expectation(description: "input read")
        never.isInverted = true
        _ = decide(state: .running, readsInput: never)
        _ = decide(enabled: false, readsInput: never)
        _ = decide(attached: false, readsInput: never)
        wait(for: [never], timeout: 0.01)
    }

    func testNoticesExplainOnlyWhatIsWorthSaying() {
        for silent in [AgentRenameOutcome.sent, .notSupported, .disabled, .notAttached] { XCTAssertNil(silent.notice) }
        for said in [AgentRenameOutcome.busy, .askingPermission, .inputNotEmpty, .inputUnknown, .agentNotInForeground] {
            XCTAssertNotNil(said.notice)
        }
    }

    func testCommandFormatting() {
        XCTAssertEqual(LaneRename.command(format: "/rename %@", name: "Docs site"), "/rename Docs site")
        XCTAssertEqual(LaneRename.command(format: "/rename %@", name: "two\nlines\r\tand\u{1B}[31m"), "/rename two lines and [31m")
        XCTAssertNil(LaneRename.command(format: "/rename %@", name: " \n "))
        XCTAssertNil(LaneRename.command(format: "/rename", name: "x"))
        XCTAssertEqual(LaneRename.cleanName(String(repeating: "a", count: 300)).count, 100)
    }

    func testBackendsKnowTheirRenameCommand() {
        XCTAssertEqual(CommandLaneBackend(id: "c", displayName: "Claude", command: "claude --model opus").renameCommand, "/rename %@")
        XCTAssertEqual(CommandLaneBackend(id: "x", displayName: "Codex", command: "/opt/bin/codex").renameCommand, "/rename %@")
        XCTAssertEqual(CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "lane-wrapper", statusAgent: "claude").renameCommand,
                       "/rename %@")
        XCTAssertNil(CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "lane-wrapper", statusAgent: nil).renameCommand)
        XCTAssertNil(CommandLaneBackend.shell.renameCommand)
        XCTAssertNil(CommandLaneBackend(id: "v", displayName: "Vim", command: "vim").renameCommand)
        // Background sessions are attached by name, so renaming one is left alone.
        XCTAssertNil(ClaudeBackgroundLaneBackend().renameCommand)
        var off = CommandLaneBackend(id: "c", displayName: "Claude", command: "claude")
        off.renameCommand = nil
        XCTAssertNil(off.renameCommand)
    }

    @MainActor
    func testRenamingADetachedLaneRenamesOnlyTheRow() {
        let defaults = UserDefaults(suiteName: "rename-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "test", sessionFileDirectory: nil, summaryCacheFile: nil,
                                                        pullRequestLedgerFile: nil, pullRequestSeedFile: nil),
                                   backends: [CommandLaneBackend(id: "claude", displayName: "Claude", command: "claude")],
                                   statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "claude")])
        XCTAssertTrue(store.renamesAgentSession)
        XCTAssertTrue(store.agentRenameAvailable)
        store.rename("a", to: "Docs")
        XCTAssertEqual(store.sessions["a"]?.title, "Docs")
        XCTAssertNil(store.sessions["a"]?.renameNotice)
        XCTAssertEqual(store.renameAgentSession("a", to: "Docs"), .notAttached)
        store.renamesAgentSession = false
        XCTAssertEqual(defaults.object(forKey: store.keys.renameAgentSession) as? Bool, false)
        XCTAssertEqual(store.renameAgentSession("a", to: "Docs"), .disabled)
        XCTAssertEqual(store.keys.renameAgentSession, "agentsmate.renameAgentSession")
    }
}

/// The reader over a real SwiftTerm screen, fed the escapes the agents draw.
final class PromptLineScreenTests: XCTestCase {
    private final class Quiet: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let quiet = Quiet()

    /// Draw `lines` from the top, then put the cursor at `cursor` (1-based row, column).
    private func screen(_ lines: [String], cursor: (row: Int, column: Int)) -> AgentPromptLine.Reading {
        let terminal = Terminal(delegate: quiet, options: TerminalOptions(cols: 60, rows: 12))
        terminal.feed(text: lines.joined(separator: "\r\n"))
        terminal.feed(text: "\u{1B}[\(cursor.row);\(cursor.column)H")
        return AgentPromptLine.read(terminal)
    }

    private let rule = "\u{1B}[38;5;244m" + String(repeating: "─", count: 60) + "\u{1B}[39m"
    private let status = "  lane │ model │ 0%"

    func testClaudePlaceholderIsEmpty() {
        let prompt = "\u{1B}[39m❯\u{00A0}\u{1B}[2mTry \"create a util logging.py that…\"\u{1B}[0m"
        XCTAssertEqual(screen(["", rule, prompt, rule, status], cursor: (3, 3)), .empty)
    }

    func testClaudeTypedTextIsNotEmpty() {
        XCTAssertEqual(screen(["", rule, "❯\u{00A0}hello there", rule, status], cursor: (3, 14)), .typed)
    }

    func testCodexPlaceholderIsEmpty() {
        let prompt = "\u{1B}[1m›\u{1B}[0m \u{1B}[2mAsk Codex to do anything\u{1B}[0m"
        XCTAssertEqual(screen(["output", "", prompt, "", "  model · folder"], cursor: (3, 3)), .empty)
        XCTAssertEqual(screen(["output", "", "\u{1B}[1m›\u{1B}[0m /rename x", "", "  model"], cursor: (3, 12)), .typed)
    }

    func testShellPromptIsUnknown() {
        XCTAssertEqual(screen(["last login", "user@host ~ % "], cursor: (2, 15)), .unknown)
    }
}

final class LaneTitleSyncTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testASessionTitleBecomesTheRowNameOnceItHoldsSteady() {
        var sync = LaneTitleSync()
        XCTAssertNil(sync.observe(title: "Entra · Update Managed Identities", rowName: "Entra 2", now: t0))
        XCTAssertEqual(sync.observe(title: "Entra · Update Managed Identities", rowName: "Entra 2", now: t0),
                       "Entra · Update Managed Identities")
        XCTAssertNil(sync.observe(title: "Entra · Update Managed Identities", rowName: "Entra · Update Managed Identities", now: t0))
    }

    func testATitleStillChangingIsNotTakenEarly() {
        var sync = LaneTitleSync()
        XCTAssertNil(sync.observe(title: "One", rowName: "Row", now: t0))
        XCTAssertNil(sync.observe(title: "Two", rowName: "Row", now: t0))
        XCTAssertEqual(sync.observe(title: "Two", rowName: "Row", now: t0), "Two")
    }

    func testARowNameWaitsForTheAgentAndTheOldTitleDoesNotOverwriteIt() {
        var sync = LaneTitleSync(acknowledged: "Old")
        sync.rowRenamed(to: "New")
        for _ in 0..<3 { XCTAssertNil(sync.observe(title: "Old", rowName: "New", now: t0)) }
        XCTAssertTrue(sync.hasPending)
        sync.typed(now: t0)
        XCTAssertFalse(sync.hasPending)
        XCTAssertNil(sync.observe(title: "Old", rowName: "New", now: t0.addingTimeInterval(5)))
        XCTAssertNil(sync.observe(title: "Old", rowName: "New", now: t0.addingTimeInterval(5)))
    }

    func testTheRenameDoesNotEchoBack() {
        var sync = LaneTitleSync(acknowledged: "Old")
        sync.rowRenamed(to: "New  name")
        sync.typed(now: t0)
        XCTAssertNil(sync.observe(title: "New name", rowName: "New  name", now: t0))
        XCTAssertEqual(sync.acknowledged, "New name")
        for _ in 0..<3 { XCTAssertNil(sync.observe(title: "New name", rowName: "New  name", now: t0)) }
    }

    func testATypedRenameThatNeverShowsStopsBlockingAfterTheWindow() {
        var sync = LaneTitleSync(acknowledged: "Old")
        sync.rowRenamed(to: "New")
        sync.typed(now: t0)
        let later = t0.addingTimeInterval(LaneTitleSync.awaitingWindow + 1)
        XCTAssertNil(sync.observe(title: "Other", rowName: "New", now: later))
        XCTAssertEqual(sync.observe(title: "Other", rowName: "New", now: later), "Other")
    }

    func testAnEmptyRenameDropsTheQueueAndLeavesTheSessionTitleSettled() {
        var sync = LaneTitleSync()
        sync.rowRenamed(to: "New")
        sync.rowReset(sessionTitle: "Agent title")
        XCTAssertFalse(sync.hasPending)
        for _ in 0..<3 { XCTAssertNil(sync.observe(title: "Agent title", rowName: nil, now: t0)) }
        XCTAssertNil(sync.observe(title: nil, rowName: nil, now: t0))
        XCTAssertNil(sync.observe(title: "Changed", rowName: nil, now: t0))
        XCTAssertEqual(sync.observe(title: "Changed", rowName: nil, now: t0), "Changed")
    }

    @MainActor
    func testTheStoreAdoptsAndKeepsARowRenameQueuedUntilItCanBeTyped() {
        let defaults = UserDefaults(suiteName: "titlesync-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "test", sessionFileDirectory: nil, summaryCacheFile: nil,
                                                        pullRequestLedgerFile: nil, pullRequestSeedFile: nil),
                                   backends: [CommandLaneBackend(id: "claude", displayName: "Claude", command: "claude")],
                                   statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "claude")])
        store.adopt(sessionTitle: "From agent", for: "a")
        XCTAssertNil(store.sessions["a"]?.customTitle)
        store.adopt(sessionTitle: "From agent", for: "a")
        XCTAssertEqual(store.sessions["a"]?.customTitle, "From agent")
        XCTAssertEqual(store.sessions["a"]?.subtitle, nil)
        XCTAssertFalse(store.sessions["a"]?.titleSync.hasPending ?? true, "adopting never queues a rename back")

        store.rename("a", to: "Mine")
        XCTAssertTrue(store.sessions["a"]?.titleSync.hasPending ?? false, "not attached here, so it stays queued")
        for _ in 0..<3 { store.adopt(sessionTitle: "From agent", for: "a") }
        XCTAssertEqual(store.sessions["a"]?.customTitle, "Mine")

        store.rename("a", to: nil)
        XCTAssertNil(store.sessions["a"]?.customTitle)
        XCTAssertFalse(store.sessions["a"]?.titleSync.hasPending ?? true)
        for _ in 0..<3 { store.adopt(sessionTitle: "From agent", for: "a") }
        XCTAssertNil(store.sessions["a"]?.customTitle, "the settled session title is not taken back")
    }
}
