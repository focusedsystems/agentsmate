import XCTest
@testable import AgentsMate
import AgentsMateStatus

final class TerminalColorSchemeRequestsTests: XCTestCase {
    func testFindsRequestsSplitAcrossReads() {
        var scanner = TerminalColorSchemeRequests()
        XCTAssertEqual(scanner.scan(Array("abc\u{1b}[?20".utf8)), [])
        XCTAssertEqual(scanner.scan(Array("31h\u{1b}[?996n\u{1b}[?2031l".utf8)), [.subscribe, .query, .unsubscribe])
    }
}

final class CommandLaneBackendTests: XCTestCase {
    private let lane = AgentLane(id: "a", title: "A", directory: URL(fileURLWithPath: "/w/it's"), backendID: "x")

    func testTmuxLanePassesTheQuotedFolder() {
        let backend = CommandLaneBackend.tmuxLane(id: "x", displayName: "X", command: "lane-wrapper", statusAgent: "claude")
        let launch = backend.launch(for: lane, shell: "/bin/zsh")
        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(launch.arguments, ["-l", "-i", "-c", "lane-wrapper '/w/it'\\''s'"])
        XCTAssertEqual(launch.directory, "/w/it's")
        XCTAssertTrue(backend.keepsRunningWhenDetached)
        XCTAssertEqual(backend.statusMatch(for: lane), .directory("/w/it's", agent: "claude"))
    }

    func testCommandCanReturnToShell() {
        let backend = CommandLaneBackend(id: "c", displayName: "C", command: "codex", returnsToShell: true)
        XCTAssertEqual(backend.launch(for: lane, shell: "/bin/zsh").arguments.last, "codex; exec '/bin/zsh' -l")
        XCTAssertEqual(backend.statusMatch(for: lane), LaneStatusMatch.none)
    }

    func testEmptyCommandIsTheLoginShell() {
        XCTAssertEqual(CommandLaneBackend.shell.launch(for: lane, shell: "/bin/bash").arguments, ["-l"])
    }

    func testEnvironmentDropsAnotherTerminalsIdentity() {
        let env = AgentLaneSession.scrubbed(["TMUX": "x", "CMUX_WORKSPACE_ID": "1", "CLAUDECODE": "1", "HOME": "/h"])
        XCTAssertEqual(env, ["HOME": "/h"])
    }
}

@MainActor
final class AgentLaneStoreTests: XCTestCase {
    private func makeStore() -> AgentLaneStore {
        let defaults = UserDefaults(suiteName: "agentsmate-tests-\(UUID().uuidString)")!
        return AgentLaneStore(configuration: .init(termProgram: "Test"),
                              backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
    }

    private func lane(_ id: String, closable: Bool = false) -> AgentLane {
        AgentLane(id: id, title: id.uppercased(), backendID: "shell", isClosable: closable)
    }

    func testSyncKeepsOpenedLanesAndSelectsFirst() {
        let store = makeStore()
        store.sync(lanes: [lane("a"), lane("b")])
        XCTAssertEqual(store.selectedID, "a")
        XCTAssertEqual(store.lanes.map(\.id), ["a", "b"])
        store.sync(lanes: [lane("b")])
        XCTAssertEqual(store.lanes.map(\.id), ["b"])
        XCTAssertEqual(store.selectedID, "b")
        XCTAssertNil(store.sessions["a"])
    }

    func testShortcutsOutsideTheSetPassThrough() {
        let store = makeStore()
        store.sync(lanes: [lane("a"), lane("b")])
        XCTAssertFalse(store.handle(.newLane, from: "a"))
        XCTAssertFalse(store.handle(.closeLane, from: "a"))
        XCTAssertTrue(store.handle(.clear, from: "a"))
    }

    func testFixedLanesCannotBeClosed() {
        let store = makeStore()
        store.sync(lanes: [lane("a")])
        store.close("a")
        XCTAssertEqual(store.lanes.map(\.id), ["a"])
    }

    func testRecordsWantingAttentionFlagLanesOutOfSight() {
        let store = makeStore()
        store.sync(lanes: [lane("a")])
        let session = store.sessions["a"]!
        session.update(record: LaneStatus(agent: "claude", state: .running, lane: "a", event: "UserPromptSubmit"))
        XCTAssertFalse(session.needsAttention)
        session.update(record: LaneStatus(agent: "claude", state: .permissionRequested, lane: "a", event: "Notification"))
        XCTAssertEqual(session.status, .permissionRequested)
        XCTAssertTrue(session.needsAttention)
        session.isShown = true
        XCTAssertFalse(session.needsAttention)
        session.update(record: LaneStatus(agent: "claude", state: .ended, lane: "a", event: "SessionEnd", updatedAt: Date(timeIntervalSinceNow: 1)))
        XCTAssertEqual(session.status, .notOpened)
    }
}

final class ClaudeBackgroundLaneBackendTests: XCTestCase {
    func testAttachesOrStartsTheFolderNamedSession() {
        let lane = AgentLane(id: "x", title: "X", directory: URL(fileURLWithPath: "/w/My Repo.app"), backendID: "claude-bg")
        let backend = ClaudeBackgroundLaneBackend()
        XCTAssertEqual(ClaudeBackgroundLaneBackend.folderName(lane), "my-repo-app")
        let line = backend.launch(for: lane, shell: "/bin/zsh").arguments.last ?? ""
        XCTAssertTrue(line.hasPrefix("out=$(claude --bg -n 'my-repo-app')"), line)
        XCTAssertTrue(line.hasSuffix("exec claude attach \"$id\""), "a new session is attached by the id it printed")
        XCTAssertFalse(line.contains("attach 'my-repo-app'"), "never attached by name")
        XCTAssertEqual(backend.statusMatch(for: lane), .lane("my-repo-app"))
    }

    func testTheStartLineReadsTheIDClaudePrints() throws {
        let line = ClaudeBackgroundLaneBackend.startLine(claude: "fake-claude", name: "Create 2", arguments: [])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        if [ "$1" = "--bg" ]; then
          printf 'backgrounded \\302\\267 b7c18466 \\302\\267 %s (idle)\\n  claude agents             list sessions\\n  claude attach b7c18466    open in this terminal\\n' "$3"
        else
          echo "$@"
        fi
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.environment = ["PATH": dir.path + ":/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(output, "attach b7c18466\n")
    }

    func testANameResolvesToAnIDExactlyThenIgnoringCaseNeverByPart() {
        let rec = { (id: String, name: String, dir: String) in
            LaneStatus(agent: "claude", state: .running, lane: name, directory: dir, sessionID: id, event: "claude agents",
                       updatedAt: Date(), agentID: id)
        }
        let records = [rec("7344ef63", "Personal - Create", "/w/create"), rec("7c4cc4bb", "create", "/w/create"),
                       rec("5fe18022", "Port the create sidebar", "/w/create"),
                       rec("bbbb0002", "Notes", "/w/create"), rec("cccc0003", "notes", "/w/create"),
                       rec("eeee0005", "Twin", "/w/create"), rec("ffff0006", "Twin", "/w/create/"),
                       rec("dddd0004", "Other", "/w/elsewhere")]
        typealias B = ClaudeBackgroundLaneBackend
        XCTAssertEqual(B.resolve(name: "create", in: "/w/create", records: records), .one("7c4cc4bb"),
                       "the one session with exactly that name, not the two that contain it")
        XCTAssertEqual(B.resolve(name: "CREATE", in: "/w/create/", records: records), .one("7c4cc4bb"), "case aside")
        XCTAssertEqual(B.resolve(name: "personal - create", in: "/w/create", records: records), .one("7344ef63"))
        XCTAssertEqual(B.resolve(name: "Twin", in: "/w/create", records: records), .several(["eeee0005", "ffff0006"]),
                       "two live sessions with the same name in one folder: attach neither")
        XCTAssertEqual(B.resolve(name: "Notes", in: "/w/create", records: records), .several(["bbbb0002", "cccc0003"]),
                       "names that differ only in case are both candidates")
        XCTAssertEqual(B.resolve(name: "Port", in: "/w/create", records: records), .none, "never part of a name")
        XCTAssertEqual(B.resolve(name: "Other", in: "/w/create", records: records), .none, "only in the lane's folder")
        let line = B.ambiguousLine(name: "NOTES", ids: ["bbbb0002", "cccc0003"])
        XCTAssertFalse(line.contains("claude"), "attaches nothing")
        XCTAssertTrue(line.contains("bbbb0002, cccc0003"))
    }

    func testAKnownIDIsAttachedAndAnotherHostsLaneIsNotGuessedHere() {
        var lane = AgentLane(id: "x", title: "X", directory: URL(fileURLWithPath: "/w/create"), backendID: "claude-bg")
        lane.agentSessionID = "7c4cc4bb"
        XCTAssertEqual(ClaudeBackgroundLaneBackend().launch(for: lane, shell: "/bin/zsh").arguments.last,
                       "exec claude attach '7c4cc4bb'")
        lane.agentSessionID = nil
        lane.host = "desk"
        let line = ClaudeBackgroundLaneBackend().launch(for: lane, shell: "/bin/zsh").arguments.last ?? ""
        XCTAssertFalse(line.contains("claude"), "neither this Mac's list nor a new session here: \(line)")
    }
}

final class SessionIDFileTests: XCTestCase {
    func testSessionIDFileWinsOverTheFolder() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agentsmate-id-\(UUID().uuidString)")
        let lane = AgentLane(id: "a", title: "A", directory: URL(fileURLWithPath: "/w"), backendID: "x")
        let backend = CommandLaneBackend.tmuxLane(id: "x", displayName: "X", command: "w", statusAgent: "claude",
                                                  sessionIDFile: { _ in file })
        XCTAssertEqual(backend.statusMatch(for: lane), .directory("/w", agent: "claude"))
        try "73f6db7c\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(backend.statusMatch(for: lane), .session("73f6db7c"))
    }
}

final class TmuxPresenceTests: XCTestCase {
    func testParsesSessionList() {
        let list = TmuxPresenceSource.parse("a\t0\t/w/a\nb\t2\t\nbad line\n")
        XCTAssertEqual(list, [LanePresence(name: "a", directory: "/w/a", attachedClients: 0),
                              LanePresence(name: "b", directory: nil, attachedClients: 2)])
        let lane = AgentLane(id: "x", title: "X", directory: URL(fileURLWithPath: "/w/a"), backendID: "s")
        XCTAssertEqual(list.find(for: lane, match: .directory("/w/a", agent: nil))?.name, "a")
        XCTAssertEqual(list.find(for: lane, match: .lane("b"))?.attachedClients, 2)
    }
}

@MainActor
final class ReopenAsTests: XCTestCase {
    func testReopenSwitchesAFixedLaneAndRemembersIt() {
        let defaults = UserDefaults(suiteName: "agentsmate-reopen-\(UUID().uuidString)")!
        let claude = CommandLaneBackend(id: "claude", displayName: "Claude", command: "true")
        let codex = CommandLaneBackend(id: "codex", displayName: "Codex", command: "true")
        func makeStore() -> AgentLaneStore {
            AgentLaneStore(configuration: .init(termProgram: "Test", reopenChoices: [
                LaneReopenChoice("Claude", backendID: "claude"), LaneReopenChoice("Codex", backendID: "codex"),
            ]), backends: [claude, codex], statusFeed: nil, defaults: defaults)
        }
        let store = makeStore()
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "claude")])
        store.reopen("a", as: "codex")
        XCTAssertEqual(store.lanes.first?.backendID, "codex")
        XCTAssertEqual(store.sessions["a"]?.backend.id, "codex")
        store.detachAll()

        let again = makeStore()
        again.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "claude")])
        XCTAssertEqual(again.lanes.first?.backendID, "codex")
        XCTAssertEqual(LaneShortcutBindings().binding(for: .reopenCodexRemote)?.display, "⇧⌘X")
    }
}

final class ClipboardRequestTests: XCTestCase {
    private let payload = Data("copied text".utf8).base64EncodedString()

    func testFindsEverySelectionAcrossReads() {
        var scanner = ClipboardRequests()
        let sequence = Array("before\u{1b}]52;;\(payload)\u{07}after".utf8)
        XCTAssertEqual(scanner.scan(sequence[0..<12]), [])
        XCTAssertEqual(scanner.scan(sequence[12...]), ["copied text"], "tmux's empty selection, split across reads")
        XCTAssertEqual(scanner.scan(Array("\u{1b}]52;c;\(payload)\u{07}".utf8)), ["copied text"], "Claude Code and Codex send c")
        XCTAssertEqual(scanner.scan(Array("\u{1b}]52;p;\(payload)\u{1b}\\".utf8)), ["copied text"], "ST terminator")
        XCTAssertEqual(scanner.scan(Array("\u{1b}]52;cs0;\(payload)\u{07}".utf8)), ["copied text"])
        XCTAssertEqual(scanner.scan(Array("\u{1b}]11;?\u{07}plain".utf8)), [])
    }

    func testSplitsAnywhere() {
        let sequence = Array("x\u{1b}]52;c;\(payload)\u{1b}\\y".utf8)
        for cut in 1..<sequence.count {
            var scanner = ClipboardRequests()
            let found = scanner.scan(sequence[0..<cut]) + scanner.scan(sequence[cut...])
            XCTAssertEqual(found, ["copied text"], "cut at \(cut)")
        }
    }

    func testNeverAnswersAReadAndSkipsBadWrites() {
        var scanner = ClipboardRequests()
        XCTAssertEqual(scanner.scan(Array("\u{1b}]52;c;?\u{07}".utf8)), [], "a query is not a write")
        XCTAssertEqual(scanner.scan(Array("\u{1b}]52;;?\u{1b}\\".utf8)), [])
        XCTAssertEqual(scanner.scan(Array("\u{1b}]52;c;\u{07}".utf8)), [], "an empty write would only wipe the clipboard")
        XCTAssertEqual(scanner.scan(Array("\u{1b}]52;x;\(payload)\u{07}".utf8)), [], "unknown selection")
        XCTAssertEqual(scanner.scan(Array("\u{1b}]52;c;\(payload)\u{1b}[0m\u{07}".utf8)), [], "cut short by another escape")
    }

    func testUnwrapsTmuxPassthrough() {
        let inner = "\u{1b}]52;c;\(payload)\u{07}".replacingOccurrences(of: "\u{1b}", with: "\u{1b}\u{1b}")
        let wrapped = Array("\u{1b}Ptmux;\(inner)\u{1b}\\".utf8)
        var scanner = ClipboardRequests()
        XCTAssertEqual(scanner.scan(wrapped), ["copied text"])
        for cut in 1..<wrapped.count {
            var split = ClipboardRequests()
            XCTAssertEqual(split.scan(wrapped[0..<cut]) + split.scan(wrapped[cut...]), ["copied text"], "cut at \(cut)")
        }
        let st = "\u{1b}]52;;\(payload)\u{1b}\\".replacingOccurrences(of: "\u{1b}", with: "\u{1b}\u{1b}")
        XCTAssertEqual(scanner.scan(Array("\u{1b}Ptmux;\(st)\u{1b}\\".utf8)), ["copied text"], "inner ST terminator")
    }
}
