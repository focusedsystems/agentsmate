import XCTest
@testable import AgentsMate
import AgentsMateStatus

final class HostSessionsParseTests: XCTestCase {
    private let agents = """
    [{"id":"7724e818","sessionId":"7724e818-aaaa","name":"Business","cwd":"/w/business","kind":"background","state":"working"},
     {"id":"ef28618f","sessionId":"3309095f-bbbb","name":"Business notes","cwd":"/w/business","kind":"background","state":"done"},
     {"pid":1,"sessionId":"cccc","name":"hand run","cwd":"/w/business","kind":"interactive","status":"busy"}]
    """

    private func output(bindings: String = "Business\t7724e818\nbad line\nOther\t-x\n", end: Bool = true) -> String {
        agents + "\n" + HostSessions.tmuxMark + "\nrepo\nrepo-2\n" + HostSessions.bindingsMark + "\n" + bindings
            + (end ? HostSessions.endMark + "\n" : "")
    }

    func testParsesTheThreeListings() throws {
        let listing = try XCTUnwrap(HostSessions.parse(output()))
        XCTAssertEqual(listing.claude.map(\.agentID), ["7724e818", "ef28618f"], "background sessions only, by short id")
        XCTAssertEqual(listing.tmux, ["repo", "repo-2"])
        XCTAssertEqual(listing.bindings, ["Business": "7724e818"], "malformed lines and ids are dropped")
    }

    func testAnAnswerThatDoesNotReachTheEndIsUnknown() {
        XCTAssertNil(HostSessions.parse(output(end: false)))
        XCTAssertNil(HostSessions.parse(""))
    }

    func testRemoteListingIsReadOnlySSHInBatchMode() throws {
        let config = HostSessionsConfiguration()
        let remote = try XCTUnwrap(HostSessions.command(host: "hub-mac", config: config))
        XCTAssertEqual(remote.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(remote.arguments.prefix(7)), ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T", "--", "hub-mac"])
        XCTAssertFalse(remote.arguments.last!.contains("--bg"), "the listing starts nothing")
        XCTAssertNil(HostSessions.command(host: "-oProxyCommand=x", config: config))
        XCTAssertEqual(HostSessions.command(host: nil, config: config)?.executable, "/bin/zsh")
    }

    func testTheLocalScriptRunsToTheEndEvenWhenTheBindingsGlobMatchesNothing() throws {
        let config = HostSessionsConfiguration(claude: "/usr/bin/false", tmux: "/usr/bin/false",
                                               bindingsCommand: #"for f in /nonexistent-agentsmate/*; do [ -f "$f" ] && echo "$f"; done"#)
        let command = try XCTUnwrap(HostSessions.command(host: nil, config: config))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(HostSessions.parse(String(decoding: data, as: UTF8.self)), HostSessionListing())
    }
}

final class HostSessionsTargetTests: XCTestCase {
    private let config = HostSessionsConfiguration()
    private let tmuxLane = CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "wrapper", statusAgent: "claude",
                                                       tmuxSessions: TmuxLaneSessions(sessionName: { @Sendable _ in "repo" }))

    private func record(_ id: String, name: String, state: LaneState = .running) -> LaneStatus {
        LaneStatus(agent: "claude", state: state, lane: name, directory: "/w/repo", sessionID: id + "-full",
                   event: "claude agents", agentID: id)
    }

    private let lane = AgentLane(id: "Business", title: "Business", directory: URL(fileURLWithPath: "/w/repo"), backendID: "t")

    func testABoundLaneAttachesItsSessionByShortID() {
        let listing = HostSessionListing(claude: [record("7724e818", name: "renamed by summary")], tmux: ["repo"],
                                         bindings: ["Business": "7724e818"])
        XCTAssertEqual(HostSessions.target(for: lane, backend: tmuxLane, listing: listing, config: config, remoteHost: "hub"),
                       .claude(id: "7724e818", host: "hub"))
    }

    func testABindingToASessionNoLongerListedAttachesNothing() {
        let listing = HostSessionListing(claude: [record("other123", name: "Business")], tmux: ["repo"],
                                         bindings: ["Business": "7724e818"])
        XCTAssertNil(HostSessions.target(for: lane, backend: tmuxLane, listing: listing, config: config, remoteHost: nil),
                     "neither the tmux name nor a same-named session stands in for the bound one")
    }

    func testATmuxLaneAttachesOnlyItsWholeName() {
        XCTAssertEqual(HostSessions.target(for: lane, backend: tmuxLane, listing: .init(tmux: ["repo-2", "repo"]),
                                           config: config, remoteHost: nil), .tmux(name: "repo", host: nil))
        XCTAssertNil(HostSessions.target(for: lane, backend: tmuxLane, listing: .init(tmux: ["repo-2", "myrepo"]),
                                         config: config, remoteHost: nil))
    }

    func testAClaudeBackgroundLaneAttachesTheOneSessionWithExactlyItsName() {
        let bg = ClaudeBackgroundLaneBackend(name: { @Sendable _ in "repo" })
        let listing = HostSessionListing(claude: [record("aaaa1111", name: "repo-app"), record("bbbb2222", name: "repo")])
        XCTAssertEqual(HostSessions.target(for: lane, backend: bg, listing: listing, config: config, remoteHost: nil),
                       .claude(id: "bbbb2222", host: nil))
        let twice = HostSessionListing(claude: [record("aaaa1111", name: "repo"), record("bbbb2222", name: "repo")])
        XCTAssertNil(HostSessions.target(for: lane, backend: bg, listing: twice, config: config, remoteHost: nil),
                     "two sessions with the name: ambiguous, so none")
        let ended = HostSessionListing(claude: [record("bbbb2222", name: "repo", state: .ended)])
        XCTAssertNil(HostSessions.target(for: lane, backend: bg, listing: ended, config: config, remoteHost: nil))
    }

    func testANonPersistentLaneIsNeverAttached() {
        XCTAssertNil(HostSessions.target(for: lane, backend: CommandLaneBackend.shell, listing: .init(tmux: ["repo"]),
                                         config: config, remoteHost: nil))
    }

    func testLaunchesAttachAndNothingElse() throws {
        let remote = try XCTUnwrap(HostSessions.launch(.claude(id: "7724e818", host: "hub-mac"), lane: lane,
                                                       shell: "/bin/zsh", config: config))
        let line = remote.arguments.last!
        XCTAssertTrue(line.hasPrefix("exec '/usr/bin/ssh' -t"), line)
        XCTAssertTrue(line.contains("'hub-mac'"), line)
        XCTAssertTrue(line.contains("attach"), line)
        XCTAssertTrue(line.contains("7724e818"), line)
        XCTAssertFalse(line.contains("--bg"), "no fallback that starts a session")
        XCTAssertFalse(line.contains("||"), "no fallback at all")
        let local = try XCTUnwrap(HostSessions.launch(.tmux(name: "repo", host: nil), lane: lane, shell: "/bin/zsh", config: config))
        XCTAssertEqual(local.arguments.last, "exec 'tmux' attach-session -t '=repo'")
        XCTAssertNil(HostSessions.launch(.tmux(name: "repo", host: "-bad"), lane: lane, shell: "/bin/zsh", config: config))
    }
}

@MainActor
final class HostSessionsStoreTests: XCTestCase {
    /// Commands that do nothing, so a test that attaches runs no real
    /// ssh, tmux or claude.
    private let inert = HostSessionsConfiguration(claude: "/usr/bin/true", tmux: "/usr/bin/true", ssh: "/usr/bin/true")
    private let hosts = AgentHosts(hosts: [.init(name: "hub-mac", role: .hub), .init(name: "lane-mac", role: .lane),
                                           .init(name: "laptop", role: .client)], selfName: "laptop")

    private func store(host: String?) -> AgentLaneStore {
        let defaults = UserDefaults(suiteName: "agentsmate-hosts-\(UUID().uuidString)")!
        let backend = CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "wrapper", statusAgent: "claude",
                                                  tmuxSessions: TmuxLaneSessions(sessionName: { @Sendable _ in "repo" }))
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, sharedLanes: nil,
                                                  hostSessions: inert)
        config.findsDetachedSessions = false
        let store = AgentLaneStore(configuration: config, backends: [backend], statusFeed: nil, defaults: defaults)
        var lane = AgentLane(id: "r", title: "Repo", directory: URL(fileURLWithPath: "/w/repo"), backendID: "t")
        lane.host = host
        store.add(lane, open: false)
        store.selectedID = "r"
        return store
    }

    func testLaunchWaitsForTheHubAndAttachesTheLanesSessionThere() {
        let store = store(host: nil)
        store.enterAgentsMode()
        store.openSelectedOnShow()
        XCTAssertFalse(store.sessions["r"]?.isAttached ?? true, "nothing until the hub answers")
        XCTAssertEqual(store.launchAttachPending, "r")
        store.received(.init(tmux: ["repo"]), from: "hub-mac", hosts: hosts)
        XCTAssertTrue(store.sessions["r"]?.isAttached ?? false)
        store.detachAll()
    }

    func testTheSameNameOnAnotherHostNeverMatches() {
        let store = store(host: "lane-mac")
        store.enterAgentsMode()
        store.openSelectedOnShow()
        store.received(.init(tmux: ["repo"]), from: "hub-mac", hosts: hosts)
        XCTAssertFalse(store.sessions["r"]?.isAttached ?? true, "the lane runs on lane-mac, not the hub")
        XCTAssertEqual(store.launchAttachPending, "r", "still waiting for its own host")
        store.received(.init(tmux: []), from: "lane-mac", hosts: hosts)
        XCTAssertFalse(store.sessions["r"]?.isAttached ?? true)
        XCTAssertNil(store.launchAttachPending)
    }

    func testAnUnknownHostAttachesNothingAndIsNotTakenAsGone() {
        let store = store(host: nil)
        store.enterAgentsMode()
        store.openSelectedOnShow()
        store.received(nil, from: "hub-mac", hosts: hosts)
        XCTAssertTrue(store.unknownHosts.contains("hub-mac"))
        XCTAssertNil(store.hostListings["hub-mac"])
        XCTAssertFalse(store.sessions["r"]?.isAttached ?? true)
        XCTAssertNotNil(store.lanes.first { $0.id == "r" }, "the row stays")
    }

    func testOpeningAnotherLaneCancelsTheWait() {
        let store = store(host: nil)
        store.enterAgentsMode()
        store.openSelectedOnShow()
        store.showDock()
        XCTAssertNil(store.launchAttachPending)
        store.detachAll()
    }
}
