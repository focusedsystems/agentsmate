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
        XCTAssertEqual(backend.launch(for: lane, shell: "/bin/zsh").arguments.last,
                       "claude attach 'my-repo-app' 2>/dev/null || { claude --bg -n 'my-repo-app' >/dev/null && exec claude attach 'my-repo-app'; }")
        XCTAssertEqual(backend.statusMatch(for: lane), .lane("my-repo-app"))
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
        XCTAssertEqual(LaneShortcutBindings().binding(for: .reopenAs2)?.display, "⌃⌥2")
    }
}
