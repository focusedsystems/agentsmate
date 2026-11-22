import XCTest
@testable import AgentsMate
import AgentsMateStatus

final class HostSessionsParseTests: XCTestCase {
    private let agents = """
    [{"id":"7724e818","sessionId":"7724e818-aaaa","name":"Business","cwd":"/w/business","kind":"background","state":"working"},
     {"id":"ef28618f","sessionId":"3309095f-bbbb","name":"Business notes","cwd":"/w/business","kind":"background","state":"done"},
     {"pid":1,"sessionId":"cccc","name":"hand run","cwd":"/w/business","kind":"interactive","status":"busy"}]
    """

    private let marks = HostSessions.Marks(nonce: "n0nce")

    private func output(bindings: String = "Business\t7724e818\nbad line\nOther\t-x\n", status: Int = 0,
                        end: Bool = true) -> String {
        agents + "\n" + marks.tmux + "\nrepo\nrepo-2\n" + marks.bindings + "\n" + bindings
            + marks.status + "\(status)\n" + (end ? marks.end + "\n" : "")
    }

    func testParsesTheThreeListings() throws {
        let listing = try XCTUnwrap(HostSessions.parse(output(), marks: marks))
        XCTAssertEqual(listing.claude.map(\.agentID), ["7724e818", "ef28618f"], "background sessions only, by short id")
        XCTAssertEqual(listing.tmux, ["repo", "repo-2"])
        XCTAssertEqual(listing.bindings, ["Business": "7724e818"], "malformed lines and ids are dropped")
    }

    func testAnAnswerThatDoesNotReachTheEndIsUnknown() {
        XCTAssertNil(HostSessions.parse(output(end: false), marks: marks))
        XCTAssertNil(HostSessions.parse("", marks: marks))
    }

    func testAMarkInsideASessionNameOrAnotherNonceCannotMoveTheFrame() {
        let forged = HostSessions.Marks(nonce: "guess")
        let sneaky = output().replacingOccurrences(of: "\nrepo\n", with: "\n" + forged.end + "\nrepo\n")
        XCTAssertNotNil(HostSessions.parse(sneaky, marks: marks), "another nonce's marks are just text")
        let inline = output().replacingOccurrences(of: "\nrepo\n", with: "\nrepo " + marks.end + "\n")
        XCTAssertEqual(HostSessions.parse(inline, marks: marks)?.tmux, ["repo " + marks.end, "repo-2"],
                       "a mark that is not a whole line is not a mark")
        let twice = output().replacingOccurrences(of: "\nrepo\n", with: "\n" + marks.end + "\n")
        XCTAssertNil(HostSessions.parse(twice, marks: marks), "a mark twice is no frame")
    }

    func testFailedBindingsAreNotKnownAndAMissingCommandIsNone() throws {
        let failed = try XCTUnwrap(HostSessions.parse(output(status: 1), marks: marks))
        XCTAssertFalse(failed.bindingsKnown)
        XCTAssertTrue(failed.bindings.isEmpty)
        let missing = try XCTUnwrap(HostSessions.parse(output(bindings: "", status: 127), marks: marks))
        XCTAssertTrue(missing.bindingsKnown)
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
                                               bindingsCommand: #"for f in /nonexistent-agentsmate/*; do [ -f "$f" ] && echo "$f"; done; true"#)
        let command = try XCTUnwrap(HostSessions.command(host: nil, config: config, marks: marks))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(HostSessions.parse(String(decoding: data, as: UTF8.self), marks: marks), HostSessionListing())
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

    func testUnknownBindingsAttachNothingForAnyLane() {
        let listing = HostSessionListing(claude: [record("7724e818", name: "x")], tmux: ["repo"], bindingsKnown: false)
        XCTAssertNil(HostSessions.target(for: lane, backend: tmuxLane, listing: listing, config: config, remoteHost: nil),
                     "the lane may be bound, so its tmux name does not stand in")
    }

    func testANameOnlyClaudeMatchMustWorkInTheLanesFolder() {
        let bg = ClaudeBackgroundLaneBackend(name: { @Sendable _ in "repo" })
        var elsewhere = record("bbbb2222", name: "repo")
        elsewhere.directory = "/somewhere/else"
        XCTAssertNil(HostSessions.target(for: lane, backend: bg, listing: .init(claude: [elsewhere]),
                                         config: config, remoteHost: nil))
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
    /// Every command is /usr/bin/true, so the store's own asks come back
    /// empty after the test; each test hands it the answers itself.
    private var inert: HostSessionsConfiguration {
        HostSessionsConfiguration(claude: "/usr/bin/true", tmux: "/usr/bin/true", ssh: "/usr/bin/true", hosts: hosts)
    }
    private let hosts = AgentHosts(hosts: [.init(name: "hub-mac", role: .hub, platform: "mac"),
                                           .init(name: "lane-mac", role: .lane, platform: "mac"),
                                           .init(name: "win-box", role: .lane, platform: "windows"),
                                           .init(name: "laptop", role: .client, platform: "mac")], selfName: "laptop")

    func testOnlyHubAndLaneMacsAreAsked() {
        XCTAssertEqual(HostSessions.askedHosts(hosts).map(\.name), ["hub-mac", "lane-mac"])
        let unstated = AgentHosts(hosts: [.init(name: "hub-mac", role: .hub)], selfName: "x")
        XCTAssertTrue(HostSessions.askedHosts(unstated).isEmpty, "a host whose platform is not given is not asked")
    }

    func testALaneOnAHostThatIsNotAMacIsLeftToAttachByHand() {
        let store = store(host: "win-box")
        store.enterAgentsMode()
        store.openSelectedOnShow()
        store.received(.init(tmux: ["repo"]), from: "hub-mac", hosts: hosts)
        XCTAssertNil(store.launchAttachPending, "win-box is never asked, so nothing waits on it")
        XCTAssertFalse(store.sessions["r"]?.isAttached ?? true)
    }

    private func store(host: String?, backend: any LaneBackend = CommandLaneBackend.tmuxLane(
        id: "t", displayName: "T", command: "wrapper", statusAgent: "claude",
        tmuxSessions: TmuxLaneSessions(sessionName: { @Sendable _ in "repo" }))) -> AgentLaneStore {
        let defaults = UserDefaults(suiteName: "agentsmate-hosts-\(UUID().uuidString)")!
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, sharedLanes: nil,
                                                  hostSessions: inert)
        config.findsDetachedSessions = false
        let store = AgentLaneStore(configuration: config, backends: [backend], statusFeed: nil, defaults: defaults)
        var lane = AgentLane(id: "r", title: "Repo", directory: URL(fileURLWithPath: "/w/repo"), backendID: backend.id)
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

    func testTheHostComesFromHowTheBackendRunsTheLane() {
        let wrapper = store(host: nil)
        XCTAssertEqual(wrapper.sessionHost(for: wrapper.lanes[0]), "hub-mac", "a wrapper lane with no host runs on the hub")
        let pinned = store(host: "lane-mac")
        XCTAssertEqual(pinned.sessionHost(for: pinned.lanes[0]), "lane-mac")
        let stranger = store(host: "not-in-registry")
        XCTAssertNil(stranger.sessionHost(for: stranger.lanes[0]), "a host outside the registry is never asked")
        let bg = store(host: "lane-mac", backend: ClaudeBackgroundLaneBackend(name: { @Sendable _ in "repo" }))
        XCTAssertEqual(bg.sessionHost(for: bg.lanes[0]), "laptop", "a backend that ignores a lane's host runs here")
        let fixed = store(host: nil, backend: CommandLaneBackend.tmuxLane(
            id: "t", displayName: "T", command: "w", statusAgent: "claude",
            tmuxSessions: TmuxLaneSessions(sessionName: { @Sendable _ in "repo" }, host: "elsewhere")))
        XCTAssertNil(fixed.sessionHost(for: fixed.lanes[0]), "a backend's own host must be in the registry")
    }
}

