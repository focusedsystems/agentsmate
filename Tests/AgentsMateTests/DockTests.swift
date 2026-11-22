import XCTest
@testable import AgentsMate

@MainActor
final class DockTests: XCTestCase {
    func testShowHideAndShortcuts() {
        let defaults = UserDefaults(suiteName: "agentsmate-dock-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "T", shortcuts: .all, sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        XCTAssertFalse(store.handle(.togglePanel, from: "x"), "no dock open, the key goes on to the menus")
        store.showDock()
        XCTAssertTrue(store.dockVisible)
        XCTAssertEqual(store.lanes.count, 1, "showing an empty dock opens a lane")
        let id = store.lanes[0].id
        XCTAssertTrue(store.handle(.maximize, from: id))
        XCTAssertTrue(store.dockMaximized)
        XCTAssertTrue(store.handle(.togglePanel, from: id))
        XCTAssertFalse(store.dockVisible)
        store.showDock()
        XCTAssertTrue(store.dockMaximized, "the dock opens in the mode it was last in")
        store.detachAll()
    }
}

@MainActor
final class CloseHookTests: XCTestCase {
    func testKeepRowEndsTerminalButKeepsLane() {
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-close-\(UUID().uuidString)")!)
        store.add(AgentLane(id: "r", title: "Repo", backendID: "shell", isClosable: true), open: false)
        store.add(AgentLane(id: "s", title: "Scratch", backendID: "shell", isClosable: true), open: false)
        var told: [String] = []
        store.willCloseLane = { lane, _ in lane.id == "r" ? .keepRow : .remove }
        store.didCloseLane = { lane, decision in told.append("\(lane.id):\(decision)") }
        store.close("r")
        store.close("s")
        XCTAssertEqual(store.lanes.map(\.id), ["r"])
        XCTAssertNotNil(store.sessions["r"])
        XCTAssertEqual(told, ["r:keepRow", "s:remove"])
    }
}

@MainActor
final class AttentionTests: XCTestCase {
    func testUnreadAndJump() {
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil, notifies: true),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-att-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "shell"), AgentLane(id: "b", title: "B", backendID: "shell")])
        let b = store.sessions["b"]!
        b.update(record: LaneStatus(agent: "claude", state: .running, lane: "b", event: "UserPromptSubmit"))
        b.update(record: LaneStatus(agent: "claude", state: .permissionRequested, lane: "b", event: "Notification"))
        XCTAssertEqual(store.unreadLanes.map(\.id), ["b"])
        XCTAssertTrue(store.jumpToUnread())
        XCTAssertEqual(store.selectedID, "b")
        store.detachAll()
    }
}
import AgentsMateStatus

@MainActor
final class HistoryPaletteTests: XCTestCase {
    func testBackForwardAndPalette() {
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-hist-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "a", title: "Alpha", directory: URL(fileURLWithPath: "/w/alpha"), backendID: "shell"),
                           AgentLane(id: "b", title: "Beta", directory: URL(fileURLWithPath: "/w/beta"), backendID: "shell"),
                           AgentLane(id: "c", title: "Gamma", directory: URL(fileURLWithPath: "/w/gamma"), backendID: "shell")])
        store.open("a", focus: false); store.open("b", focus: false); store.open("c", focus: false)
        store.goBack()
        XCTAssertEqual(store.selectedID, "b")
        store.goBack()
        XCTAssertEqual(store.selectedID, "a")
        XCTAssertFalse(store.canGoBack)
        store.goForward()
        XCTAssertEqual(store.selectedID, "b")
        XCTAssertEqual(store.paletteResults("gam").map(\.id), ["c"])
        XCTAssertEqual(store.paletteResults("w beta").map(\.id), ["b"])
        XCTAssertEqual(store.paletteResults("").count, 3)
        store.detachAll()
    }
}

@MainActor
final class AgentsLaunchTests: XCTestCase {
    func testLaunchOpensAgentsModeAndFullScreenUnlessTurnedOff() {
        let defaults = UserDefaults(suiteName: "agentsmate-launch-\(UUID().uuidString)")!
        let keys = AgentsModeKeys(prefix: "app.")
        XCTAssertTrue(AgentsLaunch.opensAgentsMode(keys, defaults: defaults))
        XCTAssertTrue(AgentsLaunch.opensFullScreen(keys, defaults: defaults))
        defaults.set(false, forKey: keys.agentsModeAtLaunch)
        defaults.set(false, forKey: keys.fullScreenAtLaunch)
        XCTAssertFalse(AgentsLaunch.opensAgentsMode(keys, defaults: defaults))
        XCTAssertFalse(AgentsLaunch.opensFullScreen(keys, defaults: defaults))
    }

    func testEnterAgentsModeFillsTheWindowAndStartsNothing() {
        let defaults = UserDefaults(suiteName: "agentsmate-launch-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        store.add(AgentLane(id: "r", title: "Repo", backendID: "shell", isClosable: false), open: false)
        store.selectedID = "r"
        store.enterAgentsMode()
        store.openSelectedOnShow()
        XCTAssertTrue(store.dockVisible)
        XCTAssertTrue(store.dockMaximized)
        XCTAssertEqual(store.lanes.map(\.id), ["r"], "no lane is created")
        XCTAssertFalse(store.sessions["r"]?.isAttached ?? false, "a lane not running is not started at launch")
        store.openSelectedOnShow()
        XCTAssertTrue(store.sessions["r"]?.isAttached ?? false, "after launch, showing the lanes opens the selected one")
        store.detachAll()
    }

    func testEnterAgentsModeWithNoLanesCreatesNone() {
        let defaults = UserDefaults(suiteName: "agentsmate-launch-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        store.enterAgentsMode()
        store.openSelectedOnShow()
        XCTAssertTrue(store.dockVisible)
        XCTAssertTrue(store.lanes.isEmpty, "launch with no lanes opens none, unlike showDock")
    }

    func testShowDockOnRequestStillOpensTheSelectedLane() {
        let defaults = UserDefaults(suiteName: "agentsmate-launch-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        store.add(AgentLane(id: "r", title: "Repo", backendID: "shell", isClosable: false), open: false)
        store.selectedID = "r"
        store.showDock()
        XCTAssertTrue(store.sessions["r"]?.isAttached ?? false)
        store.detachAll()
    }

    func testASameFolderSessionNeverStartsANonPersistentLaneAtLaunch() {
        let defaults = UserDefaults(suiteName: "agentsmate-launch-\(UUID().uuidString)")!
        let plain = CommandLaneBackend(id: "plain", displayName: "Plain", command: "true")
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [plain], statusFeed: nil, defaults: defaults)
        let folder = URL(fileURLWithPath: "/w/repo", isDirectory: true)
        store.add(AgentLane(id: "r", title: "Repo", directory: folder, backendID: "plain", isClosable: false,
                            statusMatch: .directory("/w/repo", agent: nil)), open: false)
        store.selectedID = "r"
        store.sessions["r"]?.resumeOnStart = true
        store.apply(presence: [LanePresence(name: "someone-else", directory: "/w/repo", attachedClients: 0)])
        XCTAssertTrue(store.sessions["r"]?.isPresent ?? false, "the folder match still marks the row as running")
        XCTAssertFalse(store.sessions["r"]?.isPresentByName ?? true)
        store.enterAgentsMode()
        store.openSelectedOnShow()
        XCTAssertFalse(store.sessions["r"]?.isAttached ?? true, "no process starts for a session matched by folder alone")
        XCTAssertNil(store.sessions["r"]?.shellPID)
    }

    func testPresenceFindsNothingForALaneWithNoStatusAndSaysHowItMatched() {
        let list = [LanePresence(name: "a", directory: "/w/a", attachedClients: 0)]
        let lane = AgentLane(id: "x", title: "X", directory: URL(fileURLWithPath: "/w/a"), backendID: "s")
        XCTAssertNil(list.find(for: lane, match: .none))
        XCTAssertEqual(list.locate(for: lane, match: .lane("a"))?.byName, true)
        XCTAssertEqual(list.locate(for: lane, match: .directory("/w/a", agent: nil))?.byName, false)
        XCTAssertEqual(list.locate(for: lane, match: .session("abc"))?.byName, false)
    }
}

/// A persistent backend that counts which launch the store asked for.
private final class LaunchCounter: @unchecked Sendable {
    var launches = 0
    var attaches = 0
}

private struct CountingBackend: LaneBackend {
    let id = "counting"
    let displayName = "Counting"
    let keepsRunningWhenDetached = true
    let counter: LaunchCounter
    let canAttach: Bool

    func launch(for lane: AgentLane, shell: String) -> TerminalLaunch {
        counter.launches += 1
        return TerminalLaunch(executable: "/usr/bin/true", arguments: [], directory: lane.path)
    }

    func statusMatch(for lane: AgentLane) -> LaneStatusMatch { .lane("own") }

    func attachLaunch(for lane: AgentLane, sessionName: String, shell: String) -> TerminalLaunch? {
        guard canAttach, sessionName == "own" else { return nil }
        counter.attaches += 1
        return TerminalLaunch(executable: "/usr/bin/true", arguments: [], directory: lane.path)
    }
}

@MainActor
final class AttachOnlyLaunchTests: XCTestCase {
    private func store(_ backend: CountingBackend) -> AgentLaneStore {
        let defaults = UserDefaults(suiteName: "agentsmate-attach-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [backend], statusFeed: nil, defaults: defaults)
        store.add(AgentLane(id: "r", title: "Repo", backendID: "counting", isClosable: false), open: false)
        store.selectedID = "r"
        store.sessions["r"]?.resumeOnStart = true
        store.apply(presence: [LanePresence(name: "own", directory: nil, attachedClients: 0)])
        return store
    }

    func testLaunchAttachesThroughTheAttachOnlyLaunchAndNeverTheStartOne() {
        let counter = LaunchCounter()
        let store = store(CountingBackend(counter: counter, canAttach: true))
        XCTAssertTrue(store.sessions["r"]?.isPresentByName ?? false)
        store.enterAgentsMode()
        store.openSelectedOnShow()
        XCTAssertGreaterThan(counter.attaches, 0, "the session is attached")
        XCTAssertEqual(counter.launches, 0, "the start launch, which can make a session, is never used")
        store.detachAll()
    }

    func testABackendWithNoAttachOnlyLaunchIsNotOpenedAtLaunch() {
        let counter = LaunchCounter()
        let store = store(CountingBackend(counter: counter, canAttach: false))
        store.enterAgentsMode()
        store.openSelectedOnShow()
        XCTAssertFalse(store.sessions["r"]?.isAttached ?? true)
        XCTAssertEqual(counter.launches, 0)
    }

    func testTmuxAttachLaunchHasNoFallback() {
        let tmux = CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "lane-wrapper", statusAgent: "claude",
                                               tmuxSessions: TmuxLaneSessions())
        var lane = AgentLane(id: "x", title: "X", directory: URL(fileURLWithPath: "/w/a"), backendID: "t")
        XCTAssertNil(tmux.attachLaunch(for: lane, sessionName: "a-lane", shell: "/bin/zsh"), "the lane resolves no name")
        lane.sessionName = "a-lane"
        let line = tmux.attachLaunch(for: lane, sessionName: "a-lane", shell: "/bin/zsh")?.arguments.last ?? ""
        XCTAssertTrue(line.hasPrefix("exec "), line)
        XCTAssertTrue(line.contains("attach-session -t '=a-lane'"), line)
        XCTAssertFalse(line.contains("lane-wrapper"), "never falls back to the wrapper")
        XCTAssertNil(tmux.attachLaunch(for: lane, sessionName: "other", shell: "/bin/zsh"), "only the lane's own name")
        XCTAssertNil(CommandLaneBackend.shell.attachLaunch(for: lane, sessionName: "a-lane", shell: "/bin/zsh"))
    }

    func testAVariantLaneResolvesItsOwnSessionOrNone() {
        func backend(variantName: String?) -> CommandLaneBackend {
            CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "lane-wrapper", statusAgent: "claude",
                                        variantFlag: "-n",
                                        variantStatusName: { @Sendable lane in lane.variant.flatMap { _ in variantName } },
                                        tmuxSessions: TmuxLaneSessions(sessionName: { @Sendable _ in "repo" }))
        }
        var duplicate = AgentLane(id: "d", title: "Repo 2", directory: URL(fileURLWithPath: "/w/repo"), backendID: "t")
        duplicate.variant = "2"
        let agreeing = CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "lane-wrapper", statusAgent: "claude",
                                                   variantFlag: "-n",
                                                   variantStatusName: { @Sendable lane in "repo-" + (lane.variant ?? "") },
                                                   tmuxSessions: TmuxLaneSessions(sessionName: { @Sendable lane in
                                                       "repo" + (lane.variant.map { "-" + $0 } ?? "") }))
        XCTAssertEqual(agreeing.sessionName(for: duplicate), "repo-2", "the duplicate's own -n session")
        XCTAssertNotNil(agreeing.attachLaunch(for: duplicate, sessionName: "repo-2", shell: "/bin/zsh"))
        XCTAssertNil(agreeing.attachLaunch(for: duplicate, sessionName: "repo", shell: "/bin/zsh"),
                     "the base lane's session is never attached for the duplicate")
        let disagreeing = backend(variantName: "repo-2")
        XCTAssertNil(disagreeing.sessionName(for: duplicate), "two names for one variant: ambiguous, so none")
        XCTAssertNil(disagreeing.attachLaunch(for: duplicate, sessionName: "repo", shell: "/bin/zsh"))
        XCTAssertNil(disagreeing.attachLaunch(for: duplicate, sessionName: "repo-2", shell: "/bin/zsh"))
        var base = duplicate
        base.variant = nil
        XCTAssertEqual(disagreeing.sessionName(for: base), "repo")
    }

    func testLaunchAttachesThePresenceNameOnlyWhenItIsTheLanesOwn() {
        let backend = CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "lane-wrapper", statusAgent: "claude",
                                                  variantFlag: "-n",
                                                  variantStatusName: { @Sendable lane in "repo-" + (lane.variant ?? "") },
                                                  tmuxSessions: TmuxLaneSessions(sessionName: { @Sendable lane in
                                                      "repo" + (lane.variant.map { "-" + $0 } ?? "") }))
        let defaults = UserDefaults(suiteName: "agentsmate-attach-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [backend], statusFeed: nil, defaults: defaults)
        var duplicate = AgentLane(id: "d", title: "Repo 2", directory: URL(fileURLWithPath: "/w/repo"), backendID: "t",
                                  isClosable: true, statusMatch: .firstOf([.lane("repo"), .lane("repo-2")]))
        duplicate.variant = "2"
        store.add(duplicate, open: false)
        store.selectedID = "d"
        store.apply(presence: [LanePresence(name: "repo", directory: "/w/repo", attachedClients: 0)])
        XCTAssertEqual(store.sessions["d"]?.presenceName, "repo")
        store.enterAgentsMode()
        store.openSelectedOnShow()
        XCTAssertFalse(store.sessions["d"]?.isAttached ?? true, "presence found the base session, not the duplicate's")
    }
}

