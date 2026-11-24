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

/// A row backend that knows its session's id from a file, the way a lane
/// wrapper records the session it attaches.
private struct FakeIDBackend: LaneBackend {
    var id = "row"
    var displayName = "Row"
    var idFile: URL
    var keepsRunningWhenDetached: Bool { true }
    func launch(for lane: AgentLane, shell: String) -> TerminalLaunch {
        TerminalLaunch(executable: "/bin/sh", arguments: ["-c", "sleep 30"], directory: "/tmp")
    }
    func statusMatch(for lane: AgentLane) -> LaneStatusMatch {
        guard let id = try? String(contentsOf: idFile, encoding: .utf8), !id.isEmpty else { return .none }
        return .session(id.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func sessionName(for lane: AgentLane) -> String? { lane.title.lowercased() }
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
        XCTAssertEqual(local.listCommand()?.arguments, ["-u", "list-sessions", "-F", TmuxLaneSessions.listFormat],
                       "tmux is told to use UTF-8, or it prints the tabs between fields as underscores without a UTF-8 locale")
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
        XCTAssertTrue(backend.launch(for: lane, shell: "/bin/zsh").arguments.last?.hasPrefix("out=$(claude --bg -n 'lane-a')") == true)
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

    func testRowsHoldSessionsByIDWhateverTheirNames() {
        let wrapper = CommandLaneBackend.tmuxLane(id: "w", displayName: "W", command: "w", statusAgent: "claude",
                                                  tmuxSessions: TmuxLaneSessions(sessionName: { $0.title.lowercased() }))
        let background = ClaudeBackgroundLaneBackend(id: "bg")
        let backends: [String: any LaneBackend] = ["w": wrapper, "bg": background]
        let found: [DetachedSessions.Found] = [
            .init(backendID: "bg", session: DiscoveredSession(kind: ClaudeBackgroundLaneBackend.kind, name: "Work - Business",
                                                              directory: "/tmp/business", sessionID: "7724e818-1111-2222")),
            .init(backendID: "bg", session: DiscoveredSession(kind: ClaudeBackgroundLaneBackend.kind, name: "Work - Other",
                                                              directory: "/tmp/other", sessionID: "aaaa0000-1111-2222")),
        ]
        let row = AgentLane(id: "business", title: "Business", directory: URL(fileURLWithPath: "/tmp/elsewhere"), backendID: "w")
        XCTAssertEqual(DetachedSessions.unclaimed(found, lanes: [row], backends: backends).count, 2,
                       "the row's name is not the session's, and its folder is not either")
        let left = DetachedSessions.unclaimed(found, lanes: [row], backends: backends, heldSessionIDs: ["business": ["7724e818"]])
        XCTAssertEqual(left.map(\.session.name), ["Work - Other"], "the start of the id the wrapper recorded is enough")
        XCTAssertEqual(DetachedSessions.heldSessionIDs(match: .firstOf([.session("abc"), .lane("x")]),
                                                      record: LaneStatus(agent: "claude", state: .running, sessionID: "def", event: "e")),
                       ["abc", "def"])
        XCTAssertTrue(DetachedSessions.sameSession("7724e818-1111", "7724e818"))
        XCTAssertFalse(DetachedSessions.sameSession("", "7724e818"))
        XCTAssertFalse(DetachedSessions.sameSession("7724e819", "7724e818"))
    }

    func testClaudeRowHoldsTheOneBackgroundSessionInItsFolder() {
        let wrapper = CommandLaneBackend.tmuxLane(id: "w", displayName: "W", command: "w", statusAgent: "claude",
                                                  tmuxSessions: TmuxLaneSessions(sessionName: { $0.title.lowercased() }))
        let codex = CommandLaneBackend.tmuxLane(id: "c", displayName: "C", command: "c", statusAgent: "codex")
        let background = ClaudeBackgroundLaneBackend(id: "bg")
        let backends: [String: any LaneBackend] = ["w": wrapper, "c": codex, "bg": background]
        let s = { (name: String, dir: String) in
            DetachedSessions.Found(backendID: "bg", session: DiscoveredSession(kind: ClaudeBackgroundLaneBackend.kind, name: name, directory: dir))
        }
        let found = [s("Work - Business", "/tmp/business/"), s("Work - Fitness", "/tmp/fitness"), s("notes", "/tmp/fitness")]
        let rows = [
            AgentLane(id: "b", title: "Business", directory: URL(fileURLWithPath: "/tmp/business"), backendID: "w"),
            AgentLane(id: "f", title: "Fitness", directory: URL(fileURLWithPath: "/tmp/fitness"), backendID: "w"),
        ]
        XCTAssertEqual(DetachedSessions.unclaimed(found, lanes: rows, backends: backends).map(\.session.name),
                       ["Work - Fitness", "notes"], "the only session in a Claude row's folder is the row's; two are not")
        let codexRow = AgentLane(id: "x", title: "Business", directory: URL(fileURLWithPath: "/tmp/business"), backendID: "c")
        XCTAssertEqual(DetachedSessions.unclaimed([found[0]], lanes: [codexRow], backends: backends).count, 1,
                       "a Codex row in the folder holds no Claude session")
        XCTAssertEqual(DetachedSessions.unclaimed([found[0]], lanes: [rows[0]], backends: backends, heldSessionIDs: ["b": ["ffff"]]).count, 1,
                       "a row that knows its session id is matched by it, not by folder")
    }

    func testBackgroundSessionsCarryTheirIDs() {
        let records = [LaneStatus(agent: "claude", state: .running, lane: "Work - Business", directory: "/tmp/b",
                                  sessionID: "7724e818-1111", event: ClaudeAgentsList.event)]
        XCTAssertEqual(ClaudeBackgroundLaneBackend.sessions(from: records, isLaneSession: nil).first?.sessionID, "7724e818-1111")
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

    func testRowThatAttachesASessionTakesItOutOfDetachedAtOnce() async throws {
        let idFile = FileManager.default.temporaryDirectory.appendingPathComponent("lane-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: idFile) }
        let session = DiscoveredSession(kind: ClaudeBackgroundLaneBackend.kind, name: "Work - Business",
                                        directory: "/tmp/business", sessionID: "7724e818-1111-2222")
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [FakeIDBackend(idFile: idFile), FakeDiscoveringBackend(id: "bg", found: [session])],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-detached-\(UUID().uuidString)")!)
        store.sync(lanes: [AgentLane(id: "business", title: "Business", directory: URL(fileURLWithPath: "/tmp/elsewhere"), backendID: "row")])
        store.sweepForDetachedSessions()
        await waitFor { !store.detachedIDs.isEmpty }
        XCTAssertEqual(store.detachedIDs.count, 1, "a row that knows no session yet holds none")

        // The row attaches, and its wrapper records the session it picked up.
        try "7724e818\n".write(to: idFile, atomically: true, encoding: .utf8)
        store.open("business", focus: false)
        XCTAssertTrue(store.detachedIDs.isEmpty, "gone as the row attaches, not at the next sweep")
        store.sweepForDetachedSessions()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(store.detachedIDs.isEmpty, "and not listed again")
        store.close("business")
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

final class DetachedPlacementTests: XCTestCase {
    private let backends: [String: any LaneBackend] = [
        "fake": FakeDiscoveringBackend(found: []),
        "remote": CommandLaneBackend.tmuxLane(id: "remote", displayName: "Remote", command: "true", statusAgent: nil,
                                              tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"], host: "other-mac")),
    ]

    private func lane(_ id: String, _ path: String?, backend: String = "fake", closable: Bool = false) -> AgentLane {
        AgentLane(id: id, title: id, directory: path.map { URL(fileURLWithPath: $0, isDirectory: true) },
                  backendID: backend, isClosable: closable)
    }

    private func owner(_ directory: String?, host: String? = nil, _ lanes: [AgentLane]) -> String? {
        DetachedSessions.owner(of: DiscoveredSession(kind: "fake", name: "s", directory: directory, host: host),
                               among: lanes, backends: backends, normalize: { $0 })
    }

    func testASessionGoesUnderTheRowWhoseFolderHoldsIt() {
        let lanes = [lane("repo", "/w/repo"), lane("other", "/w/other")]
        XCTAssertEqual(owner("/w/repo", lanes), "repo")
        XCTAssertEqual(owner("/w/repo/.worktrees/feature", lanes), "repo", "a worktree belongs to its repository")
        XCTAssertEqual(owner("/w/repo/.claude/worktrees/x", lanes), "repo")
        XCTAssertNil(owner("/w/repository", lanes), "a folder that only starts with the same name is not inside")
        XCTAssertNil(owner("/elsewhere", lanes))
        XCTAssertNil(owner(nil, lanes))
    }

    func testTheDeepestFolderWinsThenTheAppsRow() {
        let lanes = [lane("parent", "/w"), lane("mine", "/w/repo", closable: true), lane("app", "/w/repo")]
        XCTAssertEqual(owner("/w/repo/src", lanes), "app")
        XCTAssertEqual(owner("/w/notes", lanes), "parent")
    }

    func testBroadRowsAndOtherMachinesHoldNothing() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertNil(owner(home + "/x", [lane("home", home), lane("nofolder", nil)]))
        XCTAssertNil(owner("/w/repo", [lane("root", "/")]))
        XCTAssertNil(owner("/w/repo", host: "other-mac", [lane("repo", "/w/repo")]), "a local row does not hold a remote session")
        XCTAssertEqual(owner("/w/repo", host: "other-mac", [lane("remote", "/w/repo", backend: "remote")]), "remote")
    }
}

@MainActor
final class DetachedPlacementStoreTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func makeStore(_ found: [DiscoveredSession], file: URL) -> AgentLaneStore {
        AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil, workspaceFile: file),
                       backends: [FakeDiscoveringBackend(found: found)], statusFeed: nil,
                       defaults: UserDefaults(suiteName: "agentsmate-placement-\(UUID().uuidString)")!)
    }

    func testFoundSessionsSitUnderTheirFolderOnceAcrossRelaunch() async throws {
        let root = "/tmp/placement-\(UUID().uuidString)"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("placement-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let found = [DiscoveredSession(kind: "fake", name: "lane-repo", directory: root + "/repo"),
                     DiscoveredSession(kind: "fake", name: "lane-feature", directory: root + "/repo/.worktrees/feature"),
                     DiscoveredSession(kind: "fake", name: "lane-stray", directory: root + "/stray")]
        let rows = [AgentLane(id: "repo", title: "Repo", directory: URL(fileURLWithPath: root + "/repo"),
                              backendID: "fake", section: "Cloud"),
                    AgentLane(id: "next", title: "Next", directory: URL(fileURLWithPath: root + "/next"),
                              backendID: "fake", section: "Cloud")]

        for launch in 0..<2 {
            let store = makeStore(found, file: file)
            store.sync(lanes: rows)
            if launch == 1 { _ = store.restoreAtLaunch() }
            store.sweepForDetachedSessions()
            await waitFor { store.detachedIDs.count == 2 }
            let names = { (group: LaneGroup) in group.lanes.map { $0.sessionName ?? $0.id } }
            let cloud = try XCTUnwrap(store.groups.first { $0.section == "Cloud" })
            // The repository's own session is its row's; the worktree's is
            // listed just under it, once; only the stray is apart.
            XCTAssertEqual(names(cloud), ["repo", "lane-feature", "next"], "launch \(launch)")
            XCTAssertEqual(store.groups.last.map(names), ["lane-stray"])
            XCTAssertEqual(store.groups.last?.isDetached, true)
            XCTAssertEqual(store.displayOrder.count, Set(store.displayOrder.map(\.id)).count, "no row twice")
            XCTAssertTrue(store.restoreSnapshot().lanes.isEmpty, "found sessions are not saved as lanes")

            // Pinning the row brings its found session along, still after it.
            store.setPinned("repo", true)
            XCTAssertEqual(store.groups.first.map(names), ["repo", "lane-feature"])
            XCTAssertEqual(store.numberedLanes.map(\.id), ["repo"], "only the pinned row gets a number")
            store.setPinned("repo", false)
            store.saveRestore()
        }
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

/// Background sessions that share a name are told apart by their short id.
final class SharedNameSessionTests: XCTestCase {
    private let json = #"""
    [{"id":"1dcc92c7","sessionId":"1dcc92c7-aaaa","name":"same","cwd":"/tmp/repo","kind":"background","state":"working"},
     {"id":"7893df00","sessionId":"7893df00-bbbb","name":"same","cwd":"/tmp/repo","kind":"background","state":"done"},
     {"id":"ede373a7","sessionId":"ede373a7-cccc","name":"same","cwd":"/tmp/repo/wt","kind":"background","state":"blocked"},
     {"id":"0badf00d","sessionId":"0badf00d-dddd","name":"single","cwd":"/tmp/other","kind":"background","state":"done"}]
    """#

    private var records: [LaneStatus] { ClaudeAgentsList.parse(Data(json.utf8)) }

    func testEachSessionIsListedOnce() {
        let sessions = ClaudeBackgroundLaneBackend.sessions(from: records, isLaneSession: nil)
        XCTAssertEqual(sessions.map(\.agentID), ["1dcc92c7", "7893df00", "ede373a7", "0badf00d"])
        XCTAssertEqual(Set(sessions.map(\.key)).count, 4, "one key per session, not per name")
    }

    func testEachSharedNameGetsItsOwnRowAttachedByID() throws {
        var backend = ClaudeBackgroundLaneBackend()
        backend.agentsListCache = FileManager.default.temporaryDirectory.appendingPathComponent("am-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: backend.agentsListCache)
        defer { try? FileManager.default.removeItem(at: backend.agentsListCache) }
        let found = ClaudeBackgroundLaneBackend.sessions(from: records, isLaneSession: nil)
            .map { DetachedSessions.Found(backendID: backend.id, session: $0) }
        let left = DetachedSessions.unclaimed(found, lanes: [], backends: [backend.id: backend])
        XCTAssertEqual(left.count, 4)
        let shared = DetachedSessions.sharedNames(left)
        let rows = left.map { DetachedSessions.lane(for: $0, sharesName: DetachedSessions.sharesName($0, in: shared)) }
        XCTAssertEqual(Set(rows.map(\.id)).count, 4)
        XCTAssertEqual(rows.map(\.title).sorted(), ["same · 1dcc92c7", "same · 7893df00", "same · ede373a7", "single"])
        for row in rows {
            let line = backend.launch(for: row, shell: "/bin/zsh").arguments.last ?? ""
            XCTAssertEqual(line, "exec claude attach '\(row.agentSessionID ?? "")'", "attached by id, never by name")
            XCTAssertEqual(backend.statusMatch(for: row), .session(row.agentSessionID ?? ""))
        }
        XCTAssertEqual(rows.first?.statusMatch, .session("1dcc92c7-aaaa"))
    }

    func testARowHoldsOnlyItsOwnSession() {
        let backend = ClaudeBackgroundLaneBackend()
        let found = ClaudeBackgroundLaneBackend.sessions(from: records, isLaneSession: nil)
            .map { DetachedSessions.Found(backendID: backend.id, session: $0) }
        var row = AgentLane(id: "r", title: "same", directory: URL(fileURLWithPath: "/tmp/elsewhere"), backendID: backend.id)
        row.sessionName = "same"
        row.agentSessionID = "7893df00"
        let left = DetachedSessions.unclaimed(found, lanes: [row], backends: [backend.id: backend])
        XCTAssertEqual(left.compactMap(\.session.agentID), ["1dcc92c7", "ede373a7", "0badf00d"])
    }

    func testANamedLaneResolvesItsIDOnlyWhenOneMatches() {
        XCTAssertNil(ClaudeBackgroundLaneBackend.soleID(named: "same", in: "/tmp/repo", records: records),
                     "two sessions of that name in the folder: no guess")
        XCTAssertEqual(ClaudeBackgroundLaneBackend.soleID(named: "same", in: "/tmp/repo/wt", records: records), "ede373a7")
        XCTAssertEqual(ClaudeBackgroundLaneBackend.soleID(named: "single", in: "/tmp/other/", records: records), "0badf00d")
        XCTAssertNil(ClaudeBackgroundLaneBackend.soleID(named: "single", in: "/tmp/repo", records: records))
    }

    func testHostsAttachARowsOwnID() {
        let backend = ClaudeBackgroundLaneBackend()
        let listing = HostSessionListing(claude: records, bindingsKnown: true)
        var row = AgentLane(id: "r", title: "same", directory: URL(fileURLWithPath: "/tmp/repo"), backendID: backend.id)
        row.sessionName = "same"
        XCTAssertNil(HostSessions.target(for: row, backend: backend, listing: listing,
                                         config: HostSessionsConfiguration(), remoteHost: "box"),
                     "two sessions share the name and folder: none is picked")
        row.agentSessionID = "7893df00"
        XCTAssertEqual(HostSessions.target(for: row, backend: backend, listing: listing,
                                           config: HostSessionsConfiguration(), remoteHost: "box"),
                       .claude(id: "7893df00", host: "box"))
    }

    func testAWorkspaceKeepsTheID() throws {
        let lane = LaneWorkspace.Lane(backendID: "claude-bg", sessionName: "same", agentSessionID: "7893df00")
        let back = try JSONDecoder().decode(LaneWorkspace.Lane.self, from: JSONEncoder().encode(lane))
        XCTAssertEqual(back.agentSessionID, "7893df00")
    }
}

final class SharedFolderSessionTests: XCTestCase {
    func testTmuxSessionsInOneFolderAreToldApartByName() {
        let wrapper = CommandLaneBackend.tmuxLane(id: "c", displayName: "C", command: "c", statusAgent: "codex",
                                                  tmuxSessions: TmuxLaneSessions(prefixes: ["cx-"]))
        let backends: [String: any LaneBackend] = ["c": wrapper]
        let s = { (name: String) in
            DetachedSessions.Found(backendID: "c", session: DiscoveredSession(kind: "tmux", name: name, directory: "/w/tcc"))
        }
        let row = AgentLane(id: "1", title: "TCC", directory: URL(fileURLWithPath: "/w/tcc"), backendID: "c")
        let left = DetachedSessions.unclaimed([s("cx-tcc"), s("cx-munki-binary-naming")], lanes: [row], backends: backends)
        XCTAssertEqual(Set(left.map(\.session.name)), ["cx-tcc", "cx-munki-binary-naming"],
                       "a row with no name of its own takes neither of two sessions that share its folder")
        let alone = DetachedSessions.unclaimed([s("cx-tcc")], lanes: [row], backends: backends)
        XCTAssertTrue(alone.isEmpty, "a lone session in the folder is still its row's")
    }

    func testABackgroundSessionInTheFolderDoesNotHideATmuxSession() {
        let wrapper = CommandLaneBackend.tmuxLane(id: "c", displayName: "C", command: "c", statusAgent: "codex",
                                                  tmuxSessions: TmuxLaneSessions(prefixes: ["cx-"], sessionName: { "cx-" + $0.title }))
        let bg = ClaudeBackgroundLaneBackend(id: "bg")
        let backends: [String: any LaneBackend] = ["c": wrapper, "bg": bg]
        let found: [DetachedSessions.Found] = [
            .init(backendID: "c", session: DiscoveredSession(kind: "tmux", name: "cx-cimian", directory: "/w/cimian")),
            .init(backendID: "bg", session: DiscoveredSession(kind: "claude-bg", name: "cimian", directory: "/w/cimian", agentID: "14375687")),
        ]
        let row = AgentLane(id: "1", title: "cimian", directory: URL(fileURLWithPath: "/w/cimian"), backendID: "c")
        let left = DetachedSessions.unclaimed(found, lanes: [row], backends: backends)
        XCTAssertFalse(left.contains { $0.session.name == "cx-cimian" }, "the row keeps its own tmux session by name")
    }
}

final class AgentProcessTests: XCTestCase {
    func testABarePaneIsNoAgentButAClaudeBelowItIs() {
        let ps = """
          100     1 -zsh
          200   100 /bin/zsh -l
          300   100 /Users/x/.local/share/claude/versions/2.1.150 --resume abc
          400     1 /usr/bin/other
        """
        let table = AgentProcesses.parse(ps)
        XCTAssertTrue(AgentProcesses.hasAgent(under: 100, in: table))
        XCTAssertFalse(AgentProcesses.hasAgent(under: 200, in: table), "a shell alone is not an agent")
        XCTAssertFalse(AgentProcesses.hasAgent(under: 400, in: table))
        XCTAssertTrue(AgentProcesses.isAgent(command: "codex --yolo"))
        XCTAssertFalse(AgentProcesses.isAgent(command: "/bin/zsh -c claude-notes"))
    }

    func testPresenceWithoutAnAgentDoesNotCount() throws {
        let lane = AgentLane(id: "a", title: "A", directory: URL(fileURLWithPath: "/w/a"), backendID: "s")
        let list = [LanePresence(name: "munki-devops", directory: "/w/a", attachedClients: 1, hasAgent: false)]
        XCTAssertNotNil(list.find(for: lane, match: .lane("munki-devops")), "the match itself is unchanged")
        XCTAssertEqual(list.locate(for: lane, match: .session("97a86545"))?.byName, false)
    }
}

@MainActor
final class PresenceRulesTests: XCTestCase {
    private func store(_ backend: any LaneBackend, sessionID: String? = nil) -> AgentLaneStore {
        let defaults = UserDefaults(suiteName: "am-presence-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "Test"), backends: [backend], statusFeed: nil, defaults: defaults)
        var lane = AgentLane(id: "r", title: "R", directory: URL(fileURLWithPath: "/w/r"), backendID: backend.id)
        lane.agentSessionID = sessionID
        store.sync(lanes: [lane])
        return store
    }

    func testAPaneWithNoAgentProcessIsNotPresent() {
        let backend = CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "w", statusAgent: "codex",
                                                  tmuxSessions: TmuxLaneSessions(sessionName: { _ in "munki-devops" }))
        let store = store(backend)
        store.apply(presence: [LanePresence(name: "munki-devops", directory: "/w/r", attachedClients: 1, hasAgent: false)])
        XCTAssertEqual(store.sessions["r"]?.isPresent, false, "a bare shell is not an agent")
        XCTAssertEqual(store.sessions["r"]?.isActive, false)
        store.apply(presence: [LanePresence(name: "munki-devops", directory: "/w/r", attachedClients: 1, hasAgent: true)])
        XCTAssertEqual(store.sessions["r"]?.isPresent, true)
    }

    func testABackgroundRowIsNeverPresentThroughATmuxSessionInItsFolder() {
        var bg = ClaudeBackgroundLaneBackend(id: "bg")
        bg.agentsListCache = FileManager.default.temporaryDirectory.appendingPathComponent("am-none-\(UUID().uuidString)")
        let store = store(bg, sessionID: "97a86545")
        store.apply(presence: [LanePresence(name: "cx-tcc", directory: "/w/r", attachedClients: 1, hasAgent: true)])
        XCTAssertEqual(store.sessions["r"]?.isPresent, false)
    }
}

@MainActor
final class OwnSessionIDTests: XCTestCase {
    private let rowID = "agentsmate.detached:claude-bg:claude-bg\u{1}\u{1}97a86545"

    private func store(file: URL? = nil) -> AgentLaneStore {
        var bg = ClaudeBackgroundLaneBackend(id: "claude-bg")
        bg.agentsListCache = FileManager.default.temporaryDirectory.appendingPathComponent("am-none-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "am-own-\(UUID().uuidString)")!
        var configuration = AgentLaneStore.Configuration(termProgram: "Test")
        if let file { configuration.workspaceFile = file }
        return AgentLaneStore(configuration: configuration, backends: [bg], statusFeed: nil, defaults: defaults)
    }

    func testTheRowsOwnIDIsReadFromItsLaneID() {
        XCTAssertEqual(DetachedSessions.ownAgentID(ofLaneID: rowID), "97a86545")
        XCTAssertNil(DetachedSessions.ownAgentID(ofLaneID: "lane-1"))
        XCTAssertNil(DetachedSessions.ownAgentID(ofLaneID: "agentsmate.detached:w:tmux\u{1}\u{1}cx-a"))
    }

    func testASavedRowWithAnotherSessionsIDGetsItsOwnBeforeAnyAttach() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var workspace = LaneWorkspaceFile()
        workspace.restore = LaneWorkspace(name: "Last Session", lanes: [
            .init(directory: "/tmp/tcc", backendID: "claude-bg", agentSessionID: "0d4c8edf",
                  agentConversationID: "0d4c8edf-52c9-40a0-8092-59dcb2dd864d", id: rowID),
        ])
        try workspace.save(file)
        let store = store(file: file)
        store.restoreAtLaunch()
        let lane = try XCTUnwrap(store.lanes.first { $0.id == rowID })
        XCTAssertEqual(lane.agentSessionID, "97a86545")
        XCTAssertNil(lane.agentConversationID, "the other session's full id goes with it")
    }

    func testNoPathWritesAnotherSessionsIDOntoTheRow() {
        let store = store()
        var lane = AgentLane(id: rowID, title: "Munki", directory: URL(fileURLWithPath: "/tmp/tcc"), backendID: "claude-bg")
        lane.sessionName = "tcc"
        store.sync(lanes: [lane])
        let other = LaneStatus(agent: "claude", state: .running, lane: "tcc", directory: "/tmp/tcc", sessionID: "0d4c8edf-52c9-40a0-8092-59dcb2dd864d",
                               message: ClaudeAgentsList.backgroundMessage, event: ClaudeAgentsList.event, agentID: "0d4c8edf")
        store.recordBackgroundSessionIDs([other])
        XCTAssertEqual(store.lanes.first { $0.id == rowID }?.agentSessionID, "97a86545", "never the same-named session in its folder")
    }
}
