import XCTest
import AgentsMateStatus
@testable import AgentsMate

/// A backend that reports a fixed list of sessions and draws nothing.
private struct FakeDiscoveringBackend: LaneBackend {
    var id = "fake"
    var displayName = "Fake"
    var found: [DiscoveredSession]
    var keepsRunningWhenDetached: Bool { true }
    func launch(for lane: AgentLane, shell: String) -> TerminalLaunch {
        TerminalLaunch(executable: "/bin/sh", arguments: ["-c", "sleep 30"], directory: "/tmp")
    }
    func statusMatch(for lane: AgentLane) -> LaneStatusMatch { .directory(lane.path, agent: nil) }
    var canStop: Bool { true }
    func discoverSessions() async -> [DiscoveredSession] { found }
}

final class TmuxLaneSessionsTests: XCTestCase {
    private let listing = "lane-alpha\t0\t/tmp/alpha\nlane-beta\t2\t/tmp/beta\nscratch\t1\t/tmp\n"

    func testListsOnlyLaneSessions() {
        let none = TmuxLaneSessions()
        XCTAssertFalse(none.discovers)
        XCTAssertTrue(none.sessions(fromListing: listing).isEmpty, "with no prefixes nothing counts as a lane")

        let byPrefix = TmuxLaneSessions(prefixes: ["lane-"])
        let found = byPrefix.sessions(fromListing: listing)
        XCTAssertEqual(found.map(\.name), ["lane-alpha", "lane-beta"])
        XCTAssertEqual(found.first?.directory, "/tmp/alpha")
        XCTAssertEqual(found.last?.attachedClients, 2)
        XCTAssertNil(found.first?.host)

        let byRule = TmuxLaneSessions(prefixes: ["lane-"], matches: { $0 == "scratch" })
        XCTAssertEqual(byRule.sessions(fromListing: listing).map(\.name), ["scratch"], "the rule wins over prefixes")
        XCTAssertFalse(TmuxLaneSessions(prefixes: [""]).discovers, "an empty prefix matches nothing")
    }

    func testRelevanceByFolder() {
        let listing = "alpha\t0\t/tmp/work/alpha\nalpha-notes\t0\t/tmp/work/alpha/notes\nbeta\t1\t/tmp/workshop\nlane-x\t0\t/tmp/x\n"
        let byFolder = TmuxLaneSessions(prefixes: ["lane-"], isRelevant: { $0.isInside(anyOf: ["/tmp/work"]) })
        XCTAssertTrue(byFolder.discovers)
        XCTAssertEqual(byFolder.sessions(fromListing: listing).map(\.name), ["alpha", "alpha-notes"],
                       "the rule on name and folder wins over prefixes; a sibling folder with the same start is not inside")
        let either = TmuxLaneSessions(isRelevant: { $0.name.hasPrefix("lane-") || $0.isInside(anyOf: ["/tmp/workshop/"]) })
        XCTAssertEqual(either.sessions(fromListing: listing).map(\.name), ["beta", "lane-x"])
        XCTAssertTrue(TmuxLaneSessions(isRelevant: { _ in true }).discovers)
    }

    func testIsInside() {
        let session = DiscoveredSession(kind: "tmux", name: "a", directory: "/tmp/work/a/")
        XCTAssertTrue(session.isInside(anyOf: ["/tmp/work/a"]))
        XCTAssertTrue(session.isInside(anyOf: ["/elsewhere", "/tmp/work"]))
        XCTAssertFalse(session.isInside(anyOf: ["/tmp/work/a/b", "/tmp/wor", ""]))
        XCTAssertFalse(session.isInside(anyOf: [String]()))
        XCTAssertFalse(DiscoveredSession(kind: "tmux", name: "a").isInside(anyOf: ["/"]), "no folder is in no folder")
    }

    func testHostValidation() {
        for good in ["build-host", "user@build-host", "user@10.0.0.5", "[fe80::1%en0]", "host.example.test"] {
            XCTAssertTrue(TmuxLaneSessions.isValidHost(good), good)
        }
        for bad in ["", "-oProxyCommand=touch", "a b", "host;rm", "host\n", "$(id)", "host`x`", "a/b", "'host'"] {
            XCTAssertFalse(TmuxLaneSessions.isValidHost(bad), bad)
        }
        XCTAssertNil(TmuxLaneSessions(host: "-oProxyCommand=x").listCommand())
        XCTAssertNil(TmuxLaneSessions(host: "a b").remoteAttachLine(session: "lane"))
        XCTAssertNil(TmuxLaneSessions(host: "build-host").remoteAttachLine(session: "bad\nname"))
    }

    func testCommandLines() {
        let local = TmuxLaneSessions(prefixes: ["lane-"], tmux: "/opt/tmux")
        XCTAssertEqual(local.listCommand()?.executable, "/opt/tmux")
        XCTAssertEqual(local.listCommand()?.arguments, ["list-sessions", "-F", TmuxLaneSessions.listFormat])
        XCTAssertEqual(local.stopCommand(session: "lane-a"), ["/opt/tmux", "kill-session", "-t", "=lane-a"])
        XCTAssertEqual(local.localAttachLine(session: "lane it's", fallback: nil),
                       #"exec '/opt/tmux' attach-session -t '=lane it'\''s'"#)
        XCTAssertEqual(local.localAttachLine(session: "lane-a", fallback: "wrap '/tmp/a'"),
                       #"'/opt/tmux' attach-session -t '=lane-a' 2>/dev/null || wrap '/tmp/a'"#)

        let remote = TmuxLaneSessions(prefixes: ["lane-"], host: "user@build-host", remoteTmux: "/usr/local/bin/tmux",
                                      ssh: "/usr/bin/ssh", connectTimeout: 4)
        XCTAssertEqual(remote.remoteAttachLine(session: "lane-a"),
                       #"exec '/usr/bin/ssh' -t -o 'ConnectTimeout=4' -- 'user@build-host' ''\''/usr/local/bin/tmux'\'' attach-session -t '\''=lane-a'\'''"#)
        XCTAssertEqual(remote.listCommand()?.executable, "/usr/bin/ssh")
        XCTAssertEqual(remote.listCommand()?.arguments.prefix(6),
                       ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "--", "user@build-host"])
        XCTAssertEqual(remote.stopCommand(session: "lane-a")?.last, #"'/usr/local/bin/tmux' 'kill-session' '-t' '=lane-a'"#)
        XCTAssertEqual(remote.sessions(fromListing: "lane-a\t0\t/srv/a\n").first?.host, "user@build-host")
    }

    /// Runs the line a terminal would, with stand-ins for ssh and the
    /// host's tmux that print what they were given, so both levels of
    /// quoting are checked by real shells.
    func testRemoteAttachSurvivesBothShells() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tmux-quote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ssh = dir.appendingPathComponent("ssh"), tmux = dir.appendingPathComponent("tmux")
        try #"""
        #!/bin/sh
        for a in "$@"; do printf 'ssh[%s]\n' "$a"; done
        eval "last=\${$#}"
        exec /bin/sh -c "$last"
        """#.write(to: ssh, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/sh
        for a in "$@"; do printf 'tmux[%s]\n' "$a"; done
        """#.write(to: tmux, atomically: true, encoding: .utf8)
        for url in [ssh, tmux] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }

        let name = #"lane it's $(touch x) `id`; "q""#
        let sessions = TmuxLaneSessions(host: "user@build-host", remoteTmux: tmux.path, ssh: ssh.path)
        let line = try XCTUnwrap(sessions.remoteAttachLine(session: name))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("ssh[--]"))
        XCTAssertTrue(lines.contains("ssh[user@build-host]"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("tmux[") },
                       ["tmux[attach-session]", "tmux[-t]", "tmux[=\(name)]"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x").path), "nothing in the name ran")
    }

    func testBackendLaunchesAndStopsByName() {
        var backend = CommandLaneBackend.tmuxLane(id: "c", displayName: "C", command: "lane-wrapper", statusAgent: "claude",
                                                  tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"], tmux: "/opt/tmux"))
        var lane = AgentLane(id: "x", title: "X", directory: URL(fileURLWithPath: "/tmp/alpha"), backendID: "c")
        XCTAssertEqual(backend.launch(for: lane, shell: "/bin/zsh").arguments.last, "lane-wrapper '/tmp/alpha'",
                       "a row with no session name runs the wrapper as before")
        XCTAssertFalse(backend.canStop(lane), "no stop command and no name: nothing to stop")
        lane.sessionName = "lane-alpha"
        XCTAssertEqual(backend.launch(for: lane, shell: "/bin/zsh").arguments.last,
                       "'/opt/tmux' attach-session -t '=lane-alpha' 2>/dev/null || lane-wrapper '/tmp/alpha'")
        XCTAssertTrue(backend.canStop(lane))
        XCTAssertEqual(backend.statusMatch(for: lane), .lane("lane-alpha"))
        XCTAssertEqual(backend.sessionName(for: lane), "lane-alpha")

        backend.tmuxSessions?.host = "build-host"
        let remote = backend.launch(for: lane, shell: "/bin/zsh")
        XCTAssertTrue(remote.arguments.last?.hasPrefix("exec '/usr/bin/ssh' -t") == true)
        XCTAssertEqual(remote.directory, FileManager.default.homeDirectoryForCurrentUser.path)
        lane.sessionName = nil
        XCTAssertTrue(backend.launch(for: lane, shell: "/bin/zsh").arguments.last?.hasSuffix(#"'lane-wrapper '\''/tmp/alpha'\'''"#) == true,
                      "a lane with no known name runs the wrapper on the host")
        backend.tmuxSessions?.host = "-bad"
        XCTAssertTrue(backend.launch(for: lane, shell: "/bin/zsh").arguments.last?.hasPrefix("printf") == true)
    }

    func testClaudeBackgroundSessions() {
        let json = #"""
        [{"name":"lane-a","cwd":"/tmp/a","kind":"background","state":"working","sessionId":"1"},
         {"name":"typed","cwd":"/tmp/b","kind":"interactive","status":"idle","sessionId":"2"},
         {"name":"other","cwd":"/tmp/c","kind":"background","state":"done","sessionId":"3"}]
        """#
        let records = ClaudeAgentsList.parse(Data(json.utf8))
        XCTAssertEqual(ClaudeBackgroundLaneBackend.sessions(from: records, isLaneSession: nil).map(\.name), ["lane-a", "other"])
        XCTAssertEqual(ClaudeBackgroundLaneBackend.sessions(from: records, isLaneSession: { $0.hasPrefix("lane-") }).map(\.name),
                       ["lane-a"])
        XCTAssertEqual(ClaudeBackgroundLaneBackend.sessions(from: records, isLaneSession: { $0.hasPrefix("lane-") },
                                                            isRelevant: { $0.isInside(anyOf: ["/tmp/c"]) }).map(\.name),
                       ["other"], "the rule on name and folder wins over the name rule")
        var lane = AgentLane(id: "x", title: "X", directory: URL(fileURLWithPath: "/tmp/Some Folder"), backendID: "claude-bg")
        let backend = ClaudeBackgroundLaneBackend()
        XCTAssertEqual(backend.sessionName(for: lane), "some-folder")
        lane.sessionName = "lane-a"
        XCTAssertEqual(backend.statusMatch(for: lane), .lane("lane-a"))
        XCTAssertTrue(backend.launch(for: lane, shell: "/bin/zsh").arguments.last?.hasPrefix("claude attach 'lane-a'") == true)
    }
}

final class DetachedMatchingTests: XCTestCase {
    func testRowsClaimTheirSessions() {
        let named = CommandLaneBackend.tmuxLane(id: "a", displayName: "A", command: "w", statusAgent: "claude",
                                                tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"], sessionName: { "lane-" + $0.title }))
        let byFolder = CommandLaneBackend.tmuxLane(id: "b", displayName: "B", command: "w", statusAgent: "codex",
                                                   tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"]))
        let backends: [String: any LaneBackend] = ["a": named, "b": byFolder]
        let s = { (name: String, dir: String) in DiscoveredSession(kind: "tmux", name: name, directory: dir) }
        let found: [DetachedSessions.Found] = [
            .init(backendID: "a", session: s("lane-one", "/tmp/one")),
            .init(backendID: "b", session: s("lane-one", "/tmp/one")),
            .init(backendID: "a", session: s("lane-two", "/tmp/two")),
            .init(backendID: "b", session: s("lane-two", "/tmp/two")),
            .init(backendID: "b", session: s("lane-three", "/tmp/three")),
        ]
        let lanes = [
            AgentLane(id: "1", title: "one", directory: URL(fileURLWithPath: "/tmp/elsewhere"), backendID: "a"),
            AgentLane(id: "3", title: "Three", directory: URL(fileURLWithPath: "/tmp/three/"), backendID: "b"),
        ]
        let left = DetachedSessions.unclaimed(found, lanes: lanes, backends: backends)
        XCTAssertEqual(left.map(\.session.name), ["lane-two"], "claimed by name and by folder; listed once for two backends")
        XCTAssertEqual(left.first?.backendID, "a")
        let row = DetachedSessions.lane(for: left[0])
        XCTAssertEqual(row.sessionName, "lane-two")
        XCTAssertFalse(row.isClosable)
        XCTAssertEqual(row.statusMatch, .lane("lane-two"))
        XCTAssertEqual(row.id, DetachedSessions.laneID(left[0]), "the same id every launch")
    }

    func testRowsOnOtherBackendsClaimByNameOnly() {
        // A wrapper lane that may attach a tmux session or a background
        // session of the same name, and a background backend that lists them.
        let wrapper = CommandLaneBackend.tmuxLane(id: "w", displayName: "W", command: "w", statusAgent: "claude",
                                                  tmuxSessions: TmuxLaneSessions(sessionName: { $0.title }))
        let codex = CommandLaneBackend.tmuxLane(id: "c", displayName: "C", command: "c", statusAgent: "codex")
        let background = ClaudeBackgroundLaneBackend(id: "bg")
        let backends: [String: any LaneBackend] = ["w": wrapper, "c": codex, "bg": background]
        let s = { (name: String, dir: String) in DiscoveredSession(kind: ClaudeBackgroundLaneBackend.kind, name: name, directory: dir) }
        let found: [DetachedSessions.Found] = [
            .init(backendID: "bg", session: s("one", "/tmp/one")),
            .init(backendID: "bg", session: s("two", "/tmp/two")),
        ]
        let lanes = [
            AgentLane(id: "1", title: "one", directory: URL(fileURLWithPath: "/tmp/elsewhere"), backendID: "w"),
            AgentLane(id: "2", title: "Two", directory: URL(fileURLWithPath: "/tmp/two"), backendID: "c"),
        ]
        let left = DetachedSessions.unclaimed(found, lanes: lanes, backends: backends)
        XCTAssertEqual(left.map(\.session.name), ["two"], "another backend's row claims by name, never by folder alone")
    }
}

@MainActor
final class DetachedStoreTests: XCTestCase {
    private func makeStore(_ backend: FakeDiscoveringBackend, file: URL? = nil) -> AgentLaneStore {
        AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil, workspaceFile: file),
                       backends: [backend], statusFeed: nil,
                       defaults: UserDefaults(suiteName: "agentsmate-detached-\(UUID().uuidString)")!)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private let found = [DiscoveredSession(kind: "fake", name: "lane-a", directory: "/tmp/a"),
                         DiscoveredSession(kind: "fake", name: "lane-b", directory: "/tmp/b")]

    func testSweepListsUnclaimedAndDropsEnded() async throws {
        let store = makeStore(FakeDiscoveringBackend(found: found))
        store.sync(lanes: [AgentLane(id: "a", title: "A", directory: URL(fileURLWithPath: "/tmp/a"), backendID: "fake")])
        store.sweepForDetachedSessions()
        await waitFor { !store.detachedIDs.isEmpty }
        XCTAssertEqual(store.detachedIDs.count, 1)
        let row = try XCTUnwrap(store.lanes.first { store.isDetached($0.id) })
        XCTAssertEqual(row.sessionName, "lane-b")
        XCTAssertEqual(store.groups.last?.isDetached, true)
        XCTAssertEqual(store.groups.last?.section, LaneLayout.detachedSection)
        XCTAssertFalse(store.sessions[row.id]!.isStarted, "a Detached row waits until it is reattached")
        XCTAssertTrue(store.restoreSnapshot().lanes.isEmpty)

        store.sync(lanes: [AgentLane(id: "a", title: "A", directory: URL(fileURLWithPath: "/tmp/a"), backendID: "fake")])
        XCTAssertTrue(store.isDetached(row.id), "syncing the app's lanes keeps Detached rows")

        // A row added for the session's folder claims it; closing the row
        // without stopping, the default, lists the session again.
        XCTAssertFalse(store.configuration.closeStopsLane, "closing a row leaves its session running by default")
        store.add(AgentLane(id: "b", title: "B", directory: URL(fileURLWithPath: "/tmp/b"), backendID: "fake", isClosable: true),
                  open: false)
        XCTAssertTrue(store.detachedIDs.isEmpty)
        store.close("b")
        XCTAssertEqual(store.detachedIDs, [row.id])

        // Closing it with a stop does not.
        store.configuration.closeStopsLane = true
        store.add(AgentLane(id: "c", title: "C", directory: URL(fileURLWithPath: "/tmp/b"), backendID: "fake", isClosable: true),
                  open: false)
        store.close("c")
        XCTAssertTrue(store.detachedIDs.isEmpty)

        store.sweepForDetachedSessions()
        await waitFor { !store.detachedIDs.isEmpty }
        XCTAssertTrue(store.canStop(row.id))
        store.stop(row.id)
        XCTAssertTrue(store.detachedIDs.isEmpty, "stopping a Detached session takes its row away")

        store.sweepForDetachedSessions()
        await waitFor { !store.detachedIDs.isEmpty }
        XCTAssertEqual(store.detachedIDs, [row.id])
        store.register(FakeDiscoveringBackend(found: []))
        store.sweepForDetachedSessions()
        await waitFor { store.detachedIDs.isEmpty }
        XCTAssertEqual(store.lanes.map(\.id), ["a"], "a session that ended takes its row with it")
    }

    func testAdoptKeepsTheSession() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = makeStore(FakeDiscoveringBackend(found: found), file: file)
        store.addSection("Work")
        store.sweepForDetachedSessions()
        await waitFor { store.detachedIDs.count == 2 }
        let id = try XCTUnwrap(store.lanes.first { $0.sessionName == "lane-a" }?.id)
        store.adopt(id, into: "Work")
        defer { store.detachAll() }
        XCTAssertFalse(store.isDetached(id))
        let lane = try XCTUnwrap(store.lanes.first { $0.id == id })
        XCTAssertTrue(lane.isClosable)
        XCTAssertEqual(store.layout.section(of: lane), "Work")
        XCTAssertTrue(store.sessions[id]!.isAttached)
        XCTAssertEqual(store.restoreSnapshot().lanes.map(\.sessionName), ["lane-a"])

        store.saveRestore()
        let other = makeStore(FakeDiscoveringBackend(found: found), file: file)
        XCTAssertTrue(other.restoreAtLaunch())
        XCTAssertEqual(other.lanes.first?.sessionName, "lane-a")
        XCTAssertEqual(other.layout.section(of: other.lanes[0]), "Work")
        other.sweepForDetachedSessions()
        await waitFor { other.detachedIDs.count == 1 }
        XCTAssertEqual(other.lanes.filter { other.isDetached($0.id) }.map(\.sessionName), ["lane-b"],
                       "the restored lane claims its session")
    }
}

@MainActor
final class RestoreSnapshotTests: XCTestCase {
    private func makeStore(_ file: URL) -> AgentLaneStore {
        AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil, workspaceFile: file,
                                            findsDetachedSessions: false),
                       backends: [CommandLaneBackend.shell], statusFeed: nil,
                       defaults: UserDefaults(suiteName: "agentsmate-restore-\(UUID().uuidString)")!)
    }

    private func lane(_ id: String) -> AgentLane {
        AgentLane(id: id, title: id, directory: URL(fileURLWithPath: "/tmp"), backendID: "shell", isClosable: true)
    }

    func testWritesAfterChangesOnceLaunchIsSettled() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = makeStore(file)
        defer { store.detachAll() }
        store.add(lane("a"), focus: false, open: false)
        XCTAssertFalse(store.restoreWritePending, "nothing is written before the app has restored")

        store.performLaunchBehavior()
        store.add(lane("b"), focus: false)
        XCTAssertTrue(store.restoreWritePending)
        store.writeRestoreInBackground()
        store.flushWorkspaceWrites()
        let written = try XCTUnwrap(try LaneWorkspaceFile.load(file).restore)
        XCTAssertEqual(written.lanes.count, 1, "only the attached lane was open")
        XCTAssertEqual(written.lanes.first?.selected, true)

        store.detach("b")
        store.writeRestoreInBackground()
        store.flushWorkspaceWrites()
        XCTAssertNil(try LaneWorkspaceFile.load(file).restore)
    }

    func testRestoredLanesCountUntilShown() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var saved = LaneWorkspaceFile()
        saved.restore = LaneWorkspace(name: "Last Session", lanes: [
            .init(directory: "/tmp", backendID: "shell"),
            .init(directory: "/tmp", backendID: "shell", variant: "2", selected: true),
        ])
        try saved.save(file)

        let store = makeStore(file)
        XCTAssertTrue(store.restoreAtLaunch())
        XCTAssertEqual(store.lanes.count, 2, "a second lane in the same folder is its own lane")
        XCTAssertEqual(store.selected?.lane.variant, "2", "the selected lane is selected again")
        XCTAssertEqual(store.restoreSnapshot().lanes.count, 2, "restored lanes not yet shown were open too")
        store.close(store.lanes[0].id)
        XCTAssertEqual(store.restoreSnapshot().lanes.count, 1)
    }

    func testOlderFilesStillRead() throws {
        let json = #"{"workspaces":[],"restore":{"name":"Last Session","sections":[],"lanes":[{"backendID":"shell","directory":"/tmp"}]}}"#
        let file = try JSONDecoder().decode(LaneWorkspaceFile.self, from: Data(json.utf8))
        XCTAssertNil(file.restore?.lanes.first?.sessionName)
        XCTAssertNil(file.restore?.lanes.first?.variant)
    }
}
