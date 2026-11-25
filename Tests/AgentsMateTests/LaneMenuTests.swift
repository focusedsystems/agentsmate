import XCTest
import SwiftUI
import AgentsMateStatus
@testable import AgentsMate

private final class StopCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A backend that counts how often its session is stopped.
private struct SpyBackend: LaneBackend {
    var id = "spy"
    var displayName = "Spy"
    var keepsRunningWhenDetached = true
    var stops = StopCount()
    var canStop: Bool { true }
    func stop(_ lane: AgentLane) { stops.bump() }
    func launch(for lane: AgentLane, shell: String) -> TerminalLaunch {
        TerminalLaunch(executable: "/usr/bin/true", arguments: [], directory: lane.path)
    }
    func statusMatch(for lane: AgentLane) -> LaneStatusMatch { .none }
}

@MainActor
final class LaneMenuTests: XCTestCase {
    private func full() -> LaneMenuState {
        var s = LaneMenuState()
        s.needsAttention = true
        s.hasCustomName = true
        s.canStop = true
        s.canResume = true
        s.hasReopenChoices = true
        s.hasRunOnHosts = true
        s.hasPullRequests = true
        s.hasPorts = true
        s.hasBranch = true
        s.summariesAvailable = true
        s.hasAppItems = true
        return s
    }

    func testTheMenuListsTheSameItemsInTheSameOrder() {
        XCTAssertEqual(LaneMenuPlan.items(full()), [
            .command(.open), .command(.reattach), .command(.resume), .command(.resumeHere),
            .command(.switchToClaude), .command(.switchToCodex), .submenu(.reopenAs), .command(.detach), .command(.message), .command(.markRead),
            .command(.changeIcon), .command(.rename), .command(.automaticName),
            .submenu(.duplicate), .submenu(.switchAgent), .submenu(.runOn),
            .divider, .command(.pin), .submenu(.moveToSection),
            .divider, .command(.close), .command(.stop),
            .divider, .submenu(.pullRequests), .ports, .command(.copyBranch), .command(.copyPath),
            .command(.copySummary), .command(.copyLastPrompt), .command(.showInFinder),
            .divider, .appItems,
        ])
    }

    func testAnAppsOwnItemsComeLastUnderADivider() {
        var state = full()
        XCTAssertEqual(Array(LaneMenuPlan.items(state).suffix(2)), [.divider, .appItems])
        state.hasAppItems = false
        XCTAssertFalse(LaneMenuPlan.items(state).contains(.appItems))
    }

    func testAFoundSessionHasItsShorterMenu() {
        var s = LaneMenuState()
        s.isDetached = true
        s.canStop = true
        XCTAssertEqual(LaneMenuPlan.items(s), [
            .command(.reattach), .submenu(.adopt), .divider, .command(.stop), .divider,
            .command(.copyPath), .command(.showInFinder), .command(.copySessionName),
        ])
    }

    func testNamesAreTheHouseNames() {
        var s = LaneMenuState()
        s.laneTitle = "Docs"
        XCTAssertEqual(LaneMenuCommand.stop.title(for: s), "Stop Agent…")
        XCTAssertEqual(LaneMenuCommand.close.title(for: s), "Close (Keep Running)")
        XCTAssertEqual(LaneMenuCommand.open.title(for: s), "Open Docs")
        XCTAssertEqual(LaneMenuCommand.message.title(for: s), "Message Agent…")
        XCTAssertEqual(LaneMenuCommand.pin.title(for: s), "Pin")
        s.isPinned = true
        XCTAssertEqual(LaneMenuCommand.pin.title(for: s), "Unpin")
        let titles = LaneMenuCommand.allCases.map { $0.title(for: s) }
        XCTAssertFalse(titles.contains("Stop Lane"))
        XCTAssertFalse(titles.contains("Stop Session"))
    }

    func testALaneWhoseSessionEndsWithItsTerminalDoesNotClaimToKeepRunning() {
        var s = LaneMenuState()
        s.keepsRunningWhenDetached = false
        XCTAssertEqual(LaneMenuCommand.close.title(for: s), "Close")
        XCTAssertEqual(LaneMenuCommand.reattach.title(for: s), "Start Again")
    }

    func testShortcutsComeFromTheSharedBindings() {
        let bindings = LaneShortcutBindings()
        XCTAssertEqual(LaneMenuCommand.reattach.shortcutAction.flatMap { bindings.binding(for: $0) },
                       LaneKeyBinding("r", command: true, shift: true))
        XCTAssertEqual(LaneMenuCommand.message.shortcutAction.flatMap { bindings.binding(for: $0) },
                       LaneKeyBinding("k", command: true, option: true))
        XCTAssertEqual(LaneMenuCommand.switchToClaude.title(for: LaneMenuState()), "Switch to Claude")
        XCTAssertEqual(LaneMenuCommand.switchToCodex.title(for: LaneMenuState()), "Switch to Codex")
        XCTAssertEqual(LaneMenuCommand.switchToClaude.shortcutAction.flatMap { bindings.binding(for: $0) },
                       LaneKeyBinding("c", command: true, shift: true))
        XCTAssertEqual(LaneMenuCommand.switchToCodex.shortcutAction.flatMap { bindings.binding(for: $0) },
                       LaneKeyBinding("x", command: true, shift: true))
        // Close and Stop have no key: Close's terminal key, ⌘W, is Close Window's in the menu bar.
        XCTAssertNil(LaneMenuCommand.close.shortcutAction)
        XCTAssertNil(LaneMenuCommand.stop.shortcutAction)
    }

    func testHiddenCommandsLeaveNoStrayDividers() {
        let items = LaneContextMenu.visible(LaneMenuPlan.items(full()), hiding: [.markRead, .message, .close, .stop])
        XCTAssertFalse(items.contains(.command(.markRead)))
        XCTAssertFalse(items.contains(.command(.message)))
        XCTAssertNotEqual(items.first, .divider)
        XCTAssertNotEqual(items.last, .divider)
        for pair in zip(items, items.dropFirst()) { XCTAssertFalse(pair.0 == .divider && pair.1 == .divider) }
    }

    func testEveryCommandInAMenuHasItsOwnName() {
        let state = full()
        let names = LaneMenuPlan.commands(state).map { $0.title(for: state) }
        XCTAssertEqual(names.count, Set(names).count)
    }

    // MARK: Actions match their names

    private func store(_ spy: SpyBackend, closeStopsLane: Bool = false) -> AgentLaneStore {
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, notifies: false,
                                                  findsDetachedSessions: false, sharedLanes: nil,
                                                  liveSnapshotFile: nil, opensActiveOnly: false, displayedExportFile: nil)
        config.defaultsPrefix = "menu.\(UUID().uuidString)."
        config.closeStopsLane = closeStopsLane
        return AgentLaneStore(configuration: config, backends: [spy], statusFeed: nil,
                              defaults: UserDefaults(suiteName: "agentsmate-menu-\(UUID().uuidString)")!)
    }

    func testCloseNeverStopsTheSession() {
        let spy = SpyBackend()
        // Even an app that still sets the old option gets a Close that only hides.
        let store = store(spy, closeStopsLane: true)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "spy", isClosable: true),
                           AgentLane(id: "b", title: "B", backendID: "spy", isClosable: true)])
        XCTAssertNotNil(store.sessions["a"])
        store.close("a")
        XCTAssertEqual(spy.stops.count, 0, "Close must leave the agent running")
        XCTAssertNil(store.sessions["a"])
        XCTAssertFalse(store.lanes.contains { $0.id == "a" })
        store.detachAll()
    }

    func testStopEndsTheSessionAndAsksFirst() {
        let spy = SpyBackend()
        let store = store(spy)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "spy", isClosable: true)])
        let session = try! XCTUnwrap(store.sessions["a"])
        // The menu only asks; nothing is stopped until the person confirms.
        store.perform(.stop, on: session, openWindow: nil)
        XCTAssertEqual(store.menus.pendingStop, .init(id: "a", title: "A"))
        XCTAssertEqual(spy.stops.count, 0)
        store.stop("a")
        XCTAssertEqual(spy.stops.count, 1)
        store.detachAll()
    }

    func testDetachIsOnlyOfferedWhereTheSessionOutlivesItsTerminal() {
        var spy = SpyBackend()
        spy.keepsRunningWhenDetached = false
        let store = store(spy)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "spy", isClosable: true)])
        let session = try! XCTUnwrap(store.sessions["a"])
        XCTAssertFalse(store.isEnabled(.detach, for: session))
        XCTAssertTrue(store.isEnabled(.stop, for: session))
        store.detachAll()
    }

    func testClaudeBackgroundStopNeedsASessionIdToName() {
        let backend = ClaudeBackgroundLaneBackend()
        var lane = AgentLane(id: "x", title: "X", backendID: backend.id, isClosable: true)
        lane.startsNewSession = true
        XCTAssertFalse(backend.canStop(lane), "with no id, Stop would only detach")
        lane.agentSessionID = "abc123"
        XCTAssertTrue(backend.canStop(lane))
    }

    // MARK: Switch to Claude and Switch to Codex

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(),
                         isARepeat: false, keyCode: code)!
    }

    func testTerminalKeysResolveToTheSwitchCommands() {
        let bindings = LaneShortcutBindings()
        XCTAssertEqual(bindings.terminalShortcut(for: key("C", [.command, .shift], code: 8)), .reopen(.claudeRemote))
        XCTAssertEqual(bindings.terminalShortcut(for: key("X", [.command, .shift], code: 7)), .reopen(.codexRemote))
        // Keys no lane command owns are left for the menu bar.
        XCTAssertNil(bindings.terminalShortcut(for: key(",", .command, code: 43)))
        XCTAssertNil(bindings.terminalShortcut(for: key("P", [.command, .shift], code: 35)))
    }

    func testAFocusedTerminalLeavesWhatItDoesNotHandleToTheMenuBar() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let bindings = LaneShortcutBindings()
        view.shortcutResolver = { bindings.terminalShortcut(for: $0) }
        var received: [TerminalShortcut] = []
        var answer = false
        view.onShortcut = { received.append($0); return answer }
        // The store did not take it (no backend to switch to): the key goes on to the menu item.
        XCTAssertFalse(view.handleKeyDown(key("C", [.command, .shift], code: 8)))
        XCTAssertEqual(received, [.reopen(.claudeRemote)])
        answer = true
        XCTAssertTrue(view.handleKeyDown(key("X", [.command, .shift], code: 7)))
        // An unbound ⌘ key is never taken.
        received = []
        XCTAssertFalse(view.handleKeyDown(key("P", [.command, .shift], code: 35)))
        XCTAssertTrue(received.isEmpty)
    }

    private func switching() -> (AgentLaneStore, SpyBackend, SpyBackend) {
        var claude = SpyBackend(); claude.id = "cl"
        var codex = SpyBackend(); codex.id = "cx"
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, notifies: false,
                                                  findsDetachedSessions: false, sharedLanes: nil,
                                                  liveSnapshotFile: nil, opensActiveOnly: false, displayedExportFile: nil)
        config.defaultsPrefix = "switch.\(UUID().uuidString)."
        config.reopenChoices = [LaneReopenChoice("Claude", backendID: "cl", kind: .claudeRemote),
                                LaneReopenChoice("Codex", backendID: "cx", kind: .codexRemote)]
        let store = AgentLaneStore(configuration: config, backends: [claude, codex], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-switch-\(UUID().uuidString)")!)
        return (store, claude, codex)
    }

    func testSwitchRunsTheLaneOnTheOtherAgentWithoutStoppingTheFirst() throws {
        let (store, claude, codex) = switching()
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "cl", isClosable: true)])
        let session = try XCTUnwrap(store.sessions["a"])
        XCTAssertTrue(store.isEnabled(.switchToClaude, for: session))
        XCTAssertTrue(store.isEnabled(.switchToCodex, for: session))
        XCTAssertTrue(store.switchAgent("a", to: .codex))
        XCTAssertEqual(store.lanes.first?.backendID, "cx")
        XCTAssertEqual(claude.stops.count + codex.stops.count, 0, "the session it was on keeps running")
        XCTAssertTrue(store.handle(.reopen(.claudeRemote), from: "a"))
        XCTAssertEqual(store.lanes.first?.backendID, "cl")
        store.detachAll()
    }

    func testSwitchNeedsABackendThatRunsTheAgent() throws {
        let spy = SpyBackend()
        let store = store(spy)
        store.sync(lanes: [AgentLane(id: "a", title: "A", backendID: "spy", isClosable: true)])
        let session = try XCTUnwrap(store.sessions["a"])
        XCTAssertFalse(store.isEnabled(.switchToClaude, for: session))
        XCTAssertFalse(store.switchAgent("a", to: .claude))
        store.detachAll()
    }
}
