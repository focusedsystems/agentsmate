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
            .submenu(.reopenAs), .command(.detach), .command(.message), .command(.markRead),
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
}
