import XCTest
import SwiftUI
@testable import AgentsMate
import AgentsMateStatus

/// A snapshot file as the outside watcher writes one.
private func snapshotJSON(generated: Date = Date(), hosts: [String: (seen: Date?, sessions: [[String: Any]])]) -> Data {
    let f = ISO8601DateFormatter()
    var out: [String: Any] = [:]
    for (name, host) in hosts {
        out[name] = ["seen": host.seen.map(f.string(from:)) as Any, "sessions": host.sessions]
    }
    return try! JSONSerialization.data(withJSONObject: ["schema": 1, "generated": f.string(from: generated),
                                                        "hub": "hub-mac", "hosts": out])
}

private func entry(_ id: String, kind: String = "tmux", name: String? = nil, folder: String = "/work/repo",
                   state: String = "working", lane: String? = nil, agentID: String? = nil) -> [String: Any] {
    var d: [String: Any] = ["id": id, "kind": kind, "name": name ?? id, "folder": folder, "state": state,
                            "backend": "claude", "lastActivity": "2026-11-23T10:00:00Z"]
    if let lane { d["lane"] = lane }
    if let agentID { d["agentId"] = agentID }
    return d
}

private func write(_ data: Data, mode: Int = 0o600) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).json")
    FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: mode])
    return url
}

final class LiveSnapshotFileTests: XCTestCase {
    func testReadsHostsAndSessions() throws {
        let url = write(snapshotJSON(hosts: ["hub-mac": (Date(), [entry("tmux:a"), entry("tmux:b", state: "needs-you")])]))
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = try XCTUnwrap(LiveSessionSnapshot.load(url))
        XCTAssertEqual(snap.hub, "hub-mac")
        XCTAssertEqual(snap.hosts["hub-mac"]?.sessions.map(\.state), [.working, .needsYou])
        XCTAssertEqual(snap.hosts["hub-mac"]?.sessions.first?.host, "hub-mac")
    }

    func testAMissingEmptyMalformedOrOldFileIsNoSnapshot() {
        let dir = FileManager.default.temporaryDirectory
        XCTAssertNil(LiveSessionSnapshot.load(dir.appendingPathComponent("nothing-\(UUID().uuidString).json")))
        for data in [Data(), Data("{not json".utf8), Data("[]".utf8), Data(#"{"schema": 2, "hosts": {}}"#.utf8),
                     Data(#"{"schema": 1, "hosts": {}}"#.utf8)] {
            let url = write(data)
            XCTAssertNil(LiveSessionSnapshot.load(url), String(decoding: data, as: UTF8.self))
            try? FileManager.default.removeItem(at: url)
        }
        let old = write(snapshotJSON(generated: Date().addingTimeInterval(-LiveSessionSnapshot.maximumAge - 60),
                                     hosts: ["hub-mac": (Date(), [entry("tmux:a")])]))
        defer { try? FileManager.default.removeItem(at: old) }
        XCTAssertNil(LiveSessionSnapshot.load(old), "a file the watcher has not rewritten in half an hour says nothing about now")
    }

    func testAFileOthersCanWriteIsIgnored() {
        let data = snapshotJSON(hosts: ["hub-mac": (Date(), [entry("tmux:a")])])
        for mode in [0o620, 0o602, 0o666] {
            let url = write(data, mode: mode)
            XCTAssertNil(LiveSessionSnapshot.load(url), String(mode, radix: 8))
            try? FileManager.default.removeItem(at: url)
        }
        let ok = write(data, mode: 0o644)
        defer { try? FileManager.default.removeItem(at: ok) }
        XCTAssertNotNil(LiveSessionSnapshot.load(ok), "readable by others is fine; only writing is not")
    }

    func testBadEntriesAreSkippedNotTheFile() throws {
        var bad = entry("tmux:x")
        bad["state"] = "exploded"
        var elsewhere = entry("tmux:y")
        elsewhere["host"] = "other-mac"
        let data = snapshotJSON(hosts: ["hub-mac": (Date(), [bad, elsewhere, entry("tmux:ok"), ["name": "no id"]]),
                                        "../etc": (Date(), [entry("tmux:z")])])
        let snap = try XCTUnwrap(LiveSessionSnapshot.decode(data))
        XCTAssertEqual(Array(snap.hosts.keys), ["hub-mac"])
        XCTAssertEqual(snap.hosts["hub-mac"]?.sessions.map(\.id), ["tmux:ok"])
    }

    func testAHostIsStaleWhenItHasNotReported() throws {
        let now = Date()
        let snap = try XCTUnwrap(LiveSessionSnapshot.decode(snapshotJSON(hosts: [
            "hub-mac": (now.addingTimeInterval(-30), []),
            "laptop": (now.addingTimeInterval(-3 * 3600), []),
            "never": (nil, []),
        ])))
        XCTAssertFalse(snap.isStale("hub-mac", now: now))
        XCTAssertTrue(snap.isStale("laptop", now: now))
        XCTAssertTrue(snap.isStale("never", now: now))
        XCTAssertTrue(snap.isStale("unknown", now: now))
    }
}

final class LiveSnapshotMatchTests: XCTestCase {
    private let shell = CommandLaneBackend.shell

    private func snapshot(_ sessions: [[String: Any]], host: String = "hub-mac", seen: Date = Date()) -> LiveSessionSnapshot {
        LiveSessionSnapshot.decode(snapshotJSON(hosts: [host: (seen, sessions)]))!
    }

    private func lane(_ id: String, folder: String = "/work/docs", tmux: String? = nil, agentID: String? = nil) -> AgentLane {
        var lane = AgentLane(id: id, title: id, directory: URL(fileURLWithPath: folder), backendID: shell.id)
        lane.sessionName = tmux
        lane.agentSessionID = agentID
        return lane
    }

    func testTwoLanesInOneFolderEachGetTheirOwn() {
        let snap = snapshot([entry("tmux:cx-docs", folder: "/work/docs", state: "working", lane: "lane-1"),
                             entry("tmux:cx-docs-2", name: "cx-docs-2", folder: "/work/docs", state: "needs-you")])
        let first = LiveSnapshotSeed.hint(for: lane("lane-1"), backend: shell, host: "hub-mac", in: snap)
        let second = LiveSnapshotSeed.hint(for: lane("lane-2", tmux: "cx-docs-2"), backend: shell, host: "hub-mac", in: snap)
        let third = LiveSnapshotSeed.hint(for: lane("lane-3"), backend: shell, host: "hub-mac", in: snap)
        XCTAssertEqual(first?.state, .working)
        XCTAssertEqual(second?.state, .needsYou)
        XCTAssertNil(third, "a folder alone never matches")
    }

    func testMatchesOnlyOnTheLanesOwnHost() {
        let snap = snapshot([entry("tmux:repo", lane: "lane-1")], host: "other-mac")
        XCTAssertNil(LiveSnapshotSeed.hint(for: lane("lane-1"), backend: shell, host: "hub-mac", in: snap))
        XCTAssertNil(LiveSnapshotSeed.hint(for: lane("lane-1"), backend: shell, host: nil, in: snap))
        XCTAssertNotNil(LiveSnapshotSeed.hint(for: lane("lane-1"), backend: shell, host: "other-mac", in: snap))
    }

    func testAShortIDMatchesExactlyNeverByPrefix() {
        let snap = snapshot([entry("claude-bg:abcd1234", kind: "background", name: "Work", agentID: "abcd1234")])
        XCTAssertNotNil(LiveSnapshotSeed.hint(for: lane("l", agentID: "abcd1234"), backend: shell, host: "hub-mac", in: snap))
        XCTAssertNil(LiveSnapshotSeed.hint(for: lane("l", agentID: "abcd"), backend: shell, host: "hub-mac", in: snap))
    }

    func testAStaleHostsHintSaysWhenItWasSeen() {
        let seen = Date().addingTimeInterval(-7200)
        let snap = snapshot([entry("tmux:repo", lane: "l")], host: "laptop", seen: seen)
        let hint = LiveSnapshotSeed.hint(for: lane("l"), backend: shell, host: "laptop", in: snap)
        XCTAssertEqual(hint?.isStale, true)
        XCTAssertEqual(hint?.seen?.timeIntervalSince1970 ?? 0, seen.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: Scope

    private func claudeBackend() -> ClaudeBackgroundLaneBackend { ClaudeBackgroundLaneBackend(id: "bg") }

    private func registryScope(_ repos: [String]) -> @Sendable (String?, String?) -> Bool {
        { directory, _ in DiscoveredSession.isInRepository(directory, anyOf: repos) }
    }

    func testFoundSessionsNeedAScope() {
        let snap = snapshot([entry("claude-bg:aaaa1111", kind: "background", name: "A", folder: "/work/repo", agentID: "aaaa1111")])
        XCTAssertTrue(LiveSnapshotSeed.found(in: snap, selfName: "hub-mac", backends: [claudeBackend()], scope: nil).isEmpty,
                      "with no scope nothing is shown, never everything")
        XCTAssertTrue(LiveSnapshotSeed.found(in: snap, selfName: "hub-mac", backends: [claudeBackend()],
                                             scope: { _, _ in false }).isEmpty)
    }

    func testOnlyTheAppsRepositoriesAndTheirWorktreesAreFound() {
        let snap = snapshot([
            entry("claude-bg:aaaa0001", kind: "background", name: "Repo", folder: "/work/team/repo", agentID: "aaaa0001"),
            entry("claude-bg:aaaa0002", kind: "background", name: "Worktree", folder: "/work/team/repo/.worktrees/fix", agentID: "aaaa0002"),
            entry("claude-bg:aaaa0003", kind: "background", name: "Claude worktree",
                  folder: "/work/team/repo/.claude/worktrees/x", agentID: "aaaa0003"),
            entry("claude-bg:aaaa0004", kind: "background", name: "Other", folder: "/work/other/life", agentID: "aaaa0004"),
            entry("claude-bg:aaaa0005", kind: "background", name: "Below", folder: "/work/team/repo/sub", agentID: "aaaa0005"),
            entry("claude-bg:aaaa0006", kind: "background", name: "Owned", folder: "/work/team/repo", lane: "lane-x", agentID: "aaaa0006"),
            entry("claude-bg:aaaa0007", kind: "background", name: "Ended", folder: "/work/team/repo", state: "done", agentID: "aaaa0007"),
        ])
        let found = LiveSnapshotSeed.found(in: snap, selfName: "hub-mac", backends: [claudeBackend()],
                                           scope: registryScope(["/work/team/repo"]))
        XCTAssertEqual(found.map(\.session.agentID), ["aaaa0001", "aaaa0002", "aaaa0003"])
        XCTAssertTrue(found.allSatisfy { $0.backendID == "bg" && $0.session.host == nil })
    }

    func testAnotherMacsSessionsAreNeverFoundRows() {
        let snap = snapshot([entry("claude-bg:aaaa0001", kind: "background", folder: "/work/team/repo", agentID: "aaaa0001")],
                            host: "other-mac")
        XCTAssertTrue(LiveSnapshotSeed.found(in: snap, selfName: "hub-mac", backends: [claudeBackend()],
                                             scope: registryScope(["/work/team/repo"])).isEmpty)
    }
}

@MainActor
final class LiveSnapshotStoreTests: XCTestCase {
    private func store(file: URL?, scope: (@Sendable (String?, String?) -> Bool)? = nil,
                       backends: [any LaneBackend] = [CommandLaneBackend.shell]) -> AgentLaneStore {
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: file)
        config.sessionScope = scope
        return AgentLaneStore(configuration: config, backends: backends, statusFeed: nil,
                              defaults: UserDefaults(suiteName: "agentsmate-live-\(UUID().uuidString)")!)
    }

    private func lane(_ id: String, tmux: String? = nil) -> AgentLane {
        var lane = AgentLane(id: id, title: id, directory: URL(fileURLWithPath: "/work/repo"), backendID: "shell")
        lane.sessionName = tmux
        return lane
    }

    func testALaneShowsItsSnapshotStateBeforeAnythingAnswers() throws {
        let url = write(snapshotJSON(hosts: ["hub-mac": (Date(), [entry("tmux:one", lane: "one"),
                                                                 entry("tmux:two", name: "two", state: "needs-you")])]))
        defer { try? FileManager.default.removeItem(at: url) }
        let store = store(file: url)
        store.liveSelfNameOverride = "hub-mac"
        store.sync(lanes: [lane("one"), lane("two", tmux: "two"), lane("three")])
        XCTAssertEqual(store.sessions["one"]?.status, .running)
        XCTAssertEqual(store.sessions["two"]?.status, .waitingForInput)
        XCTAssertEqual(store.sessions["one"]?.isActive, true)
        XCTAssertEqual(store.sessions["three"]?.status, .notOpened)
        XCTAssertEqual(store.sessions["three"]?.isActive, false)
        XCTAssertTrue(store.startsFromLiveSnapshot)
        XCTAssertNil(store.laneLoadStages["one"], "a lane the snapshot knows is not shown as loading")
    }

    func testTheSnapshotNeverAttachesOrStartsAnything() throws {
        let url = write(snapshotJSON(hosts: ["hub-mac": (Date(), [entry("tmux:one", lane: "one")])]))
        defer { try? FileManager.default.removeItem(at: url) }
        let store = store(file: url)
        store.liveSelfNameOverride = "hub-mac"
        store.sync(lanes: [lane("one")])
        store.openSelectedOnShow(focus: false)
        let session = try XCTUnwrap(store.sessions["one"])
        XCTAssertFalse(session.isStarted)
        XCTAssertFalse(session.isAttached)
        XCTAssertNil(session.attachOnlyLaunch)
        XCTAssertNil(session.presenceName, "a snapshot entry is not presence: launch attaches nothing by it")
    }

    func testNoFileOrABadFileIsTodaysBehaviour() {
        let bad = write(Data("{".utf8))
        defer { try? FileManager.default.removeItem(at: bad) }
        for file in [nil, bad, FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")] {
            let store = store(file: file)
            store.liveSelfNameOverride = "hub-mac"
            store.sync(lanes: [lane("one")])
            XCTAssertFalse(store.startsFromLiveSnapshot)
            XCTAssertNil(store.sessions["one"]?.liveHint)
            XCTAssertEqual(store.sessions["one"]?.status, .notOpened)
        }
    }

    func testARealReportReplacesTheHint() throws {
        let url = write(snapshotJSON(hosts: ["hub-mac": (Date(), [entry("tmux:one", state: "working", lane: "one")])]))
        defer { try? FileManager.default.removeItem(at: url) }
        let store = store(file: url)
        store.liveSelfNameOverride = "hub-mac"
        store.sync(lanes: [lane("one")])
        let session = try XCTUnwrap(store.sessions["one"])
        session.update(record: LaneStatus(agent: "claude", state: .waitingForInput, lane: "one", event: "Notification"))
        XCTAssertEqual(session.status, .waitingForInput)
    }

    func testFoundRowsComeOnlyFromTheScope() async throws {
        let url = write(snapshotJSON(hosts: ["hub-mac": (Date(), [
            entry("claude-bg:aaaa0001", kind: "background", name: "Mine", folder: "/work/team/repo", agentID: "aaaa0001"),
            entry("claude-bg:aaaa0002", kind: "background", name: "Theirs", folder: "/work/other", agentID: "aaaa0002"),
        ])]))
        defer { try? FileManager.default.removeItem(at: url) }
        for (scope, expected) in [(nil, [String]()),
                                  ({ @Sendable (d: String?, _: String?) in DiscoveredSession.isInRepository(d, anyOf: ["/work/team/repo"]) }, ["Mine"])] {
            var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, sharedLanes: nil,
                                                      liveSnapshotFile: url)
            config.sessionScope = scope
            let store = AgentLaneStore(configuration: config, backends: [ClaudeBackgroundLaneBackend(id: "bg", claude: "/usr/bin/false")],
                                       statusFeed: nil, defaults: UserDefaults(suiteName: "agentsmate-live-\(UUID().uuidString)")!)
            store.liveSelfNameOverride = "hub-mac"
            store.sweepForDetachedSessions()
            let titles = store.lanes.filter { store.isDetached($0.id) }.map(\.title)
            XCTAssertEqual(titles, expected)
        }
    }

    func testAnUnreachableHostKeepsItsHintMarkedStale() throws {
        let url = write(snapshotJSON(hosts: ["lane-mac": (Date(), [entry("tmux:repo", lane: "remote")])]))
        defer { try? FileManager.default.removeItem(at: url) }
        let hosts = AgentHosts(hosts: [.init(name: "hub-mac", role: .hub, platform: "mac"),
                                       .init(name: "lane-mac", role: .lane, platform: "mac")], selfName: "hub-mac")
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: url)
        config.hostSessions = HostSessionsConfiguration(ssh: "/usr/bin/false", hosts: hosts)
        let store = AgentLaneStore(configuration: config, backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-live-\(UUID().uuidString)")!)
        var remote = lane("remote")
        remote.host = "lane-mac"
        store.received(nil, from: "lane-mac", hosts: hosts)
        store.liveSelfNameOverride = "hub-mac"
        store.sync(lanes: [remote])
        // The shell backend runs on this Mac; the hint is matched on the lane's own host.
        let session = try XCTUnwrap(store.sessions["remote"])
        session.liveHint = LiveSnapshotSeed.hint(for: remote, backend: CommandLaneBackend.shell, host: "lane-mac",
                                                 in: LiveSessionSnapshot.load(url)!)
        store.retireLiveHints()
        XCTAssertEqual(session.liveHint?.isStale, true)
        XCTAssertTrue(session.isActive)
        store.received(.init(tmux: []), from: "lane-mac", hosts: hosts)
        XCTAssertNil(session.liveHint, "once the host answers without it, the session has gone")
    }

    func testAllAgentsShowsTheBoardAtOnceFromTheSnapshot() throws {
        let url = write(snapshotJSON(hosts: ["hub-mac": (Date(), [entry("tmux:one", lane: "one"),
                                                                 entry("tmux:two", name: "two", state: "needs-you")])]))
        defer { try? FileManager.default.removeItem(at: url) }
        let store = store(file: url)
        store.liveSelfNameOverride = "hub-mac"
        store.sync(lanes: [lane("one"), lane("two", tmux: "two"), lane("three")])
        let view = AgentHomeView(store: store).frame(width: 900, height: 360)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 900)
        if let dir = ProcessInfo.processInfo.environment["AGENTSMATE_RENDER_DIR"],
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("all-agents.png"))
        }
    }

    func testActiveOnlyIsOnAtEveryLaunch() {
        let defaults = UserDefaults(suiteName: "agentsmate-live-\(UUID().uuidString)")!
        let keys = AgentsModeKeys(prefix: "agentsmate.")
        defaults.set(false, forKey: keys.filterOpen)
        _ = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                sharedLanes: nil, liveSnapshotFile: nil),
                           backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: keys.filterOpen))
    }
}

final class LiveSnapshotBoardTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testAllLanesAddsNotRunning() {
        let items = [AgentHomeItem(id: "run", status: .running, isActive: true),
                     AgentHomeItem(id: "saved", status: .notOpened, isActive: false)]
        XCTAssertEqual(AgentHome.columns(items, now: now).map(\.section), [.needsYou, .working, .recent])
        let all = AgentHome.columns(items, now: now, includesNotRunning: true)
        XCTAssertEqual(all.map(\.section), [.needsYou, .working, .recent, .notRunning])
        XCTAssertEqual(all.last?.items.map(\.id), ["saved"])
    }

    @MainActor
    func testAStaleCardRendersWithItsHost() throws {
        let lane = AgentLane(id: "l", title: "Docs", directory: URL(fileURLWithPath: "/tmp"), backendID: "shell")
        let session = AgentLaneSession(lane: lane, backend: CommandLaneBackend.shell)
        session.liveHint = LiveSessionHint(state: .working, host: "laptop", seen: Date().addingTimeInterval(-7200), isStale: true)
        let card = AgentHomeCard(session: session, area: "Web", isSelected: false, isFocused: false)
            .frame(width: 280).padding(8).background(Color.white)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, 60)
        if let dir = ProcessInfo.processInfo.environment["AGENTSMATE_RENDER_DIR"],
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("stale-card.png"))
        }
    }
}

final class LiveSnapshotWrongLaneTests: XCTestCase {
    func testABackgroundRowIgnoresASessionTheWatcherTiedToItByFolder() throws {
        let json = snapshotJSON(hosts: ["hub-mac": (Date(), [
            entry("claude-bg:0d4c8edf", name: "tcc", folder: "/w/tcc", state: "needs-you", lane: "row-bg", agentID: "0d4c8edf"),
            entry("claude-bg:97a86545", name: "Munki", folder: "/w/tcc", state: "working", agentID: "97a86545"),
        ])])
        let snap = try XCTUnwrap(LiveSessionSnapshot.decode(json))
        var row = AgentLane(id: "row-bg", title: "Munki", directory: URL(fileURLWithPath: "/w/tcc"), backendID: "claude-bg")
        row.agentSessionID = "97a86545"
        let hint = LiveSnapshotSeed.hint(for: row, backend: ClaudeBackgroundLaneBackend(), host: "hub-mac", in: snap)
        XCTAssertEqual(hint?.state, .working, "its own id, not the other session filed under its lane id")
    }
}

final class CodexBackendAppSeesBothKindsTests: XCTestCase {
    func testACodexAppFindsItsTmuxLanesAndTheBackgroundSessions() throws {
        let folders = ["/w/Systems/Inventory", "/w/Cloud/Vantage"]
        let codex = CommandLaneBackend.tmuxLane(
            id: "app.codex", displayName: "Codex", command: "cx", statusAgent: "codex",
            tmuxSessions: TmuxLaneSessions(prefixes: ["cx-"], isRelevant: { @Sendable session in
                session.name.hasPrefix("cx-") && session.isInside(anyOf: folders)
            }))
        let claude = CommandLaneBackend.tmuxLane(
            id: "app.claude", displayName: "Claude", command: "cl", statusAgent: "claude",
            tmuxSessions: TmuxLaneSessions(prefixes: [], isRelevant: { @Sendable session in
                !session.name.hasPrefix("cx-") && session.isInside(anyOf: folders)
            }))
        var background = ClaudeBackgroundLaneBackend(id: "app.claude-bg")
        background.isRelevant = { @Sendable session in session.isInside(anyOf: folders) }
        let json = snapshotJSON(hosts: ["hub-mac": (Date(), [
            entry("tmux:cx-vantage", name: "cx-vantage", folder: "/w/Cloud/Vantage", state: "idle"),
            entry("tmux:cx-vantage-2", name: "cx-vantage-2", folder: "/w/Cloud/Vantage", state: "idle"),
            entry("claude-bg:1bca8603", kind: "background", name: "Vantage worktree",
                  folder: "/w/Cloud/Vantage/.worktrees/x", state: "working", agentID: "1bca8603"),
            entry("claude-bg:8ca7673e", kind: "background", name: "Inventory", folder: "/w/Systems/Inventory",
                  state: "working", agentID: "8ca7673e"),
            entry("tmux:cx-elsewhere", name: "cx-elsewhere", folder: "/w/Other", state: "idle"),
        ])])
        let snap = try XCTUnwrap(LiveSessionSnapshot.decode(json))
        let found = LiveSnapshotSeed.found(in: snap, selfName: "hub-mac", backends: [codex, claude, background],
                                           scope: { directory, _ in
            DiscoveredSession.isInRepository(directory, anyOf: folders)
        })
        XCTAssertEqual(Set(found.map(\.session.name)),
                       ["cx-vantage", "cx-vantage-2", "Vantage worktree", "Inventory"], "both kinds, in scope only")
        XCTAssertEqual(found.filter { $0.session.kind == "tmux" }.map(\.backendID), ["app.codex", "app.codex"])
        XCTAssertEqual(found.filter { $0.session.kind == ClaudeBackgroundLaneBackend.kind }.map(\.backendID),
                       ["app.claude-bg", "app.claude-bg"])
    }
}
