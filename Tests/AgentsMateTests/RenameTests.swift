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
        XCTAssertEqual(LaneRename.cleanName(String(repeating: "a", count: 300)).count, 200)
    }

    func testBackendsKnowTheirRenameCommand() {
        XCTAssertEqual(CommandLaneBackend(id: "c", displayName: "Claude", command: "claude --model opus").renameCommand, "/rename %@")
        XCTAssertEqual(CommandLaneBackend(id: "x", displayName: "Codex", command: "/opt/bin/codex").renameCommand, "/rename %@")
        XCTAssertEqual(CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "lane-wrapper", statusAgent: "claude").renameCommand,
                       "/rename %@")
        XCTAssertNil(CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "lane-wrapper", statusAgent: nil).renameCommand)
        XCTAssertNil(CommandLaneBackend.shell.renameCommand)
        XCTAssertNil(CommandLaneBackend(id: "v", displayName: "Vim", command: "vim").renameCommand)
        XCTAssertEqual(ClaudeBackgroundLaneBackend().renameCommand, "/rename %@")
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
    func testABackgroundClaudeRowQueuesItsRenameUntilItIsAttachedAndNeverStartsIt() {
        let defaults = UserDefaults(suiteName: "titlesync-bg-\(UUID().uuidString)")!
        let backend = ClaudeBackgroundLaneBackend()
        let store = AgentLaneStore(configuration: .init(termProgram: "test", sessionFileDirectory: nil, summaryCacheFile: nil,
                                                        pullRequestLedgerFile: nil, pullRequestSeedFile: nil),
                                   backends: [backend], statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "b", title: "B", backendID: backend.id)])
        let session = store.sessions["b"]
        store.rename("b", to: "Mine")
        XCTAssertTrue(session?.titleSync.hasPending ?? false)
        store.flushPendingRenames()
        XCTAssertTrue(session?.titleSync.hasPending ?? false, "still queued, not dropped")
        XCTAssertEqual(session?.isAttached, false, "renaming never attaches or wakes the session")
        XCTAssertEqual(store.renameAgentSession("b", to: "Mine"), .notAttached)
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

final class RenameBothWaysTests: XCTestCase {
    private func decide(state: LaneState?, runsWhileBusy: Bool) -> AgentRenameOutcome {
        AgentRenameOutcome.decide(command: "/rename x", enabled: true, attached: true, agentInForeground: true,
                                  state: state, runsWhileBusy: runsWhileBusy, input: { .empty })
    }

    func testClaudeTakesARenameWhileATurnIsRunningButStillNotAtAPermissionPrompt() {
        XCTAssertEqual(decide(state: .running, runsWhileBusy: false), .busy)
        XCTAssertEqual(decide(state: .running, runsWhileBusy: true), .sent)
        XCTAssertEqual(decide(state: .permissionRequested, runsWhileBusy: true), .askingPermission)
    }

    private func listed(name: String?, worker: Bool?, id: String = "6db6dcf2") -> LaneStatus {
        LaneStatus(agent: "claude", state: .running, lane: name, directory: "/work", sessionID: "6db6dcf2-295a-489f-ba55-67beb2d1de68",
                   event: ClaudeAgentsList.event, agentID: id, workerRunning: worker)
    }

    @MainActor
    private func store(_ backend: ClaudeBackgroundLaneBackend, defaults: UserDefaults) -> AgentLaneStore {
        let store = AgentLaneStore(configuration: .init(termProgram: "test", sessionFileDirectory: nil, summaryCacheFile: nil,
                                                        pullRequestLedgerFile: nil, pullRequestSeedFile: nil),
                                   backends: [backend], statusFeed: nil, defaults: defaults)
        store.sync(lanes: [AgentLane(id: "b", title: "B", backendID: backend.id)])
        return store
    }

    @MainActor
    func testTheDaemonsNameForASessionBecomesTheRowsNameWithNoFileToRead() throws {
        let store = store(ClaudeBackgroundLaneBackend(), defaults: UserDefaults(suiteName: "rename-both-\(UUID().uuidString)")!)
        let session = try XCTUnwrap(store.sessions["b"])
        session.update(record: listed(name: "Renamed in the session", worker: true),
                       polled: listed(name: "Renamed in the session", worker: true))
        XCTAssertEqual(session.polledName, "Renamed in the session")
        store.adoptDaemonTitle(of: session)
        XCTAssertNil(session.customTitle, "a title is taken once it reads the same twice")
        store.adoptDaemonTitle(of: session)
        XCTAssertEqual(session.customTitle, "Renamed in the session")
        XCTAssertFalse(session.titleSync.hasPending, "taking the name never queues it back")
    }

    @MainActor
    func testAHookRecordsTmuxNameIsNotATitle() throws {
        let store = store(ClaudeBackgroundLaneBackend(), defaults: UserDefaults(suiteName: "rename-both-\(UUID().uuidString)")!)
        let session = try XCTUnwrap(store.sessions["b"])
        let hook = LaneStatus(agent: "claude", state: .done, lane: "tmux-name", event: "Stop")
        session.update(record: hook, polled: hook)
        XCTAssertNil(session.polledName)
    }

    @MainActor
    func testARowNotOpenHereIsRenamedThroughItsOwnAttachWhileItsSessionRuns() throws {
        let store = store(ClaudeBackgroundLaneBackend(), defaults: UserDefaults(suiteName: "rename-both-\(UUID().uuidString)")!)
        let session = try XCTUnwrap(store.sessions["b"])
        XCTAssertNil(store.headlessRenameLaunch(for: session), "nothing is listed for it")
        session.update(record: listed(name: "Old", worker: true), polled: listed(name: "Old", worker: true))
        let launch = try XCTUnwrap(store.headlessRenameLaunch(for: session))
        XCTAssertTrue(launch.arguments.joined(separator: " ").contains("attach"))
        XCTAssertTrue(launch.arguments.joined(separator: " ").contains("6db6dcf2"))
        XCTAssertFalse(launch.arguments.joined(separator: " ").contains("--bg"), "it never starts a session")
    }

    @MainActor
    func testAStoppedSessionIsNeverStartedToRenameIt() throws {
        let store = store(ClaudeBackgroundLaneBackend(), defaults: UserDefaults(suiteName: "rename-both-\(UUID().uuidString)")!)
        let session = try XCTUnwrap(store.sessions["b"])
        session.update(record: listed(name: "Old", worker: false), polled: listed(name: "Old", worker: false))
        XCTAssertNil(store.headlessRenameLaunch(for: session))
        session.update(record: listed(name: "Old", worker: nil), polled: listed(name: "Old", worker: nil))
        XCTAssertNil(store.headlessRenameLaunch(for: session))
    }

    @MainActor
    func testAQueuedRenameSurvivesARestart() throws {
        let defaults = UserDefaults(suiteName: "rename-both-\(UUID().uuidString)")!
        let first = store(ClaudeBackgroundLaneBackend(), defaults: defaults)
        first.rename("b", to: "Mine")
        XCTAssertTrue(first.sessions["b"]?.titleSync.hasPending ?? false)
        let second = store(ClaudeBackgroundLaneBackend(), defaults: defaults)
        XCTAssertEqual(second.sessions["b"]?.customTitle, "Mine")
        XCTAssertEqual(second.sessions["b"]?.titleSync.pending, "Mine")
    }

    func testTheDaemonListSaysWhetherAWorkerRunsTheSession() {
        let data = Data("""
        [{"id":"aaaaaaaa","sessionId":"aaaaaaaa-0000-0000-0000-000000000000","name":"Live","cwd":"/w","kind":"background","pid":10,"status":"idle","state":"done"},
         {"id":"bbbbbbbb","sessionId":"bbbbbbbb-0000-0000-0000-000000000000","name":"Waiting","cwd":"/w","kind":"background","state":"blocked"}]
        """.utf8)
        let records = ClaudeAgentsList.parse(data)
        XCTAssertEqual(records.map(\.workerRunning), [true, false])
    }
}

final class HeadlessAgentRenameTests: XCTestCase {
    private func script(_ body: String) throws -> TerminalLaunch {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return TerminalLaunch(executable: "/bin/sh", arguments: [url.path], directory: NSHomeDirectory())
    }

    private let quick = HeadlessAgentRename.Timing(ready: 3, confirm: 3, gap: 0.05)

    func testPlainTextJoinsWordsClaudeDrawsWithCursorMoves() {
        XCTAssertEqual(HeadlessAgentRename.plain("\u{1B}[1mSession\u{1B}[14Grenamed\u{1B}[22Gto:\u{1B}[26Gnew\r\n"), "Session renamed to: new")
    }

    private let prompt = "rule=$(printf '\\342\\224\\200%.0s' 1 2 3 4 5 6 7 8 9 10)\nprintf '%s\\n' \"$rule\"\nprintf '\\342\\235\\257\\302\\240\\0337\\n%s\\0338' \"$rule\"\n"

    func testTypesTheCommandOnlyOnceTheEmptyInputLineShowsAndReportsClaudesConfirmation() async throws {
        let launch = try script(prompt + """
        read line
        case "$line" in
          "/rename New name") printf '\\nSession\\033[14Grenamed\\033[22Gto:\\033[26GNew name\\n'; sleep 1 ;;
          *) printf 'unexpected %s\\n' "$line" ;;
        esac
        """)
        let renamed = await HeadlessAgentRename.run(launch, command: "/rename New name",
                                                    environment: ProcessInfo.processInfo.environment, timing: quick)
        XCTAssertTrue(renamed)
    }

    private func neverTyped(_ screen: String) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("typed-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let launch = try script(screen + "\nread line\necho \"$line\" > '\(marker.path)'\n")
        let short = HeadlessAgentRename.Timing(ready: 1.2, confirm: 0.6, gap: 0.05)
        let renamed = await HeadlessAgentRename.run(launch, command: "/rename X",
                                                    environment: ProcessInfo.processInfo.environment, timing: short)
        XCTAssertFalse(renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing was typed")
    }

    func testRefusesAScreenThatNeverShowsAnInputLine() async throws {
        try await neverTyped("printf 'starting\\n'")
    }

    func testRefusesAPermissionPromptEvenWithAnInputLineLookingEmpty() async throws {
        try await neverTyped(prompt + "printf '\\nDo you want to proceed?\\n'")
    }

    func testRefusesATrustPromptAndANumberedMenu() async throws {
        try await neverTyped("printf 'Do you trust this folder?\\n'")
        try await neverTyped("printf '\\342\\235\\257 1. Yes\\n  2. No\\n'")
    }

    func testRefusalReadsQuestionsAndMenusOnly() {
        XCTAssertTrue(HeadlessAgentRename.refusal(in: ["  Do you want to make this edit?"]))
        XCTAssertTrue(HeadlessAgentRename.refusal(in: ["Do you trust this folder?"]))
        XCTAssertTrue(HeadlessAgentRename.refusal(in: ["❯ 1. Yes", "  2. No"]))
        XCTAssertTrue(HeadlessAgentRename.refusal(in: ["Proceed? (y/n)"]))
        XCTAssertFalse(HeadlessAgentRename.refusal(in: ["❯ ", "⏵⏵ bypass permissions on (shift+tab to cycle)", "v2.1.332 build 1.5"]))
    }

    @MainActor
    func testAnAskingOrBlockedSessionIsNeverAttachedForARename() throws {
        let backend = ClaudeBackgroundLaneBackend()
        let store = AgentLaneStore(configuration: .init(termProgram: "test", sessionFileDirectory: nil, summaryCacheFile: nil,
                                                        pullRequestLedgerFile: nil, pullRequestSeedFile: nil),
                                   backends: [backend], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "rename-refuse-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "b", title: "B", backendID: backend.id)])
        let session = try XCTUnwrap(store.sessions["b"])
        for state in [LaneState.permissionRequested, .waitingForInput] {
            let listed = LaneStatus(agent: "claude", state: state, lane: "x", directory: "/w", sessionID: "6db6dcf2-295a-489f-ba55-67beb2d1de68",
                                    event: ClaudeAgentsList.event, agentID: "6db6dcf2", workerRunning: true)
            session.update(record: listed, polled: listed)
            XCTAssertNil(store.headlessRenameLaunch(for: session), "\(state)")
        }
    }
}
