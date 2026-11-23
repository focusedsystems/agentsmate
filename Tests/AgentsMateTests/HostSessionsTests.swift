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

    func testBindingsAreKnownOnlyWhenTheCommandSucceeds() throws {
        let failed = try XCTUnwrap(HostSessions.parse(output(status: 1), marks: marks))
        XCTAssertFalse(failed.bindingsKnown)
        XCTAssertTrue(failed.bindings.isEmpty)
        let missing = try XCTUnwrap(HostSessions.parse(output(bindings: "", status: 127), marks: marks))
        XCTAssertFalse(missing.bindingsKnown, "a missing command is a failure too")
        XCTAssertTrue(try XCTUnwrap(HostSessions.parse(output(), marks: marks)).bindingsKnown)
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


/// A Claude background session a lane owns by the bindings is that lane's
/// row alone: never also a found row, and the row's status is its.
@MainActor
final class OwnedSessionTests: XCTestCase {
    private let hosts = AgentHosts(hosts: [.init(name: "hub-mac", role: .hub, platform: "mac")], selfName: "hub-mac")
    private let folder = "/w/nutrition"

    private func store() -> AgentLaneStore {
        let defaults = UserDefaults(suiteName: "agentsmate-owned-\(UUID().uuidString)")!
        let config = AgentLaneStore.Configuration(
            termProgram: "T", sessionFileDirectory: nil, sharedLanes: nil,
            hostSessions: HostSessionsConfiguration(claude: "/usr/bin/true", tmux: "/usr/bin/true",
                                                    bindingsCommand: "/usr/bin/true", ssh: "/usr/bin/true", hosts: hosts))
        let wrapper = CommandLaneBackend.tmuxLane(id: "area", displayName: "Area", command: "wrapper", statusAgent: "claude",
                                                  tmuxSessions: TmuxLaneSessions(sessionName: { @Sendable _ in "nutrition" }))
        var background = ClaudeBackgroundLaneBackend(id: "claude-bg")
        background.discoversSessions = false
        let store = AgentLaneStore(configuration: config, backends: [wrapper, background], statusFeed: nil, defaults: defaults)
        store.add(AgentLane(id: "Nutrition", title: "Nutrition", directory: URL(fileURLWithPath: folder), backendID: "area"),
                  open: false)
        return store
    }

    private func found(_ id: String, _ name: String) -> DetachedSessions.Found {
        .init(backendID: "claude-bg", session: DiscoveredSession(kind: ClaudeBackgroundLaneBackend.kind, name: name,
                                                                 directory: folder, sessionID: id + "-1111-2222", agentID: id))
    }

    private var bothSessions: [DetachedSessions.Found] { [found("f4eced18", "Nutrition"), found("fabb4b85", "Personal - Nutrition")] }

    private func foundTitles(_ store: AgentLaneStore) -> [String] {
        store.lanes.filter { store.isDetached($0.id) }.map(\.title).sorted()
    }

    func testAnOwnedSessionIsHiddenAndItsSiblingShown() {
        let store = store()
        store.received(.init(bindings: ["Nutrition": "f4eced18"]), from: "hub-mac", hosts: hosts)
        store.received(found: bothSessions)
        XCTAssertEqual(store.ownedSession(for: store.lanes[0]), .init(host: nil, agentID: "f4eced18"),
                       "the lane runs on this Mac, so its owned session is this Mac's")
        XCTAssertEqual(foundTitles(store), ["Personal - Nutrition"],
                       "the lane's own session is its row; the other session in the folder still shows")
        let sibling = store.lanes.first { store.isDetached($0.id) }
        XCTAssertEqual(sibling?.agentSessionID, "fabb4b85", "the sibling is attached by its id")
        let records = [LaneStatus(agent: "claude", state: .running, lane: "Nutrition", directory: folder,
                                  sessionID: "f4eced18-1111-2222", event: ClaudeAgentsList.event, agentID: "f4eced18"),
                       LaneStatus(agent: "claude", state: .done, lane: "Personal - Nutrition", directory: folder,
                                  sessionID: "fabb4b85-1111-2222", event: ClaudeAgentsList.event, agentID: "fabb4b85")]
        XCTAssertEqual(store.statusMatch(for: store.sessions["Nutrition"]!, records: records), .session("f4eced18-1111-2222"),
                       "the row's status and summary come from the session it owns, found by its exact short id")
        XCTAssertEqual(store.statusMatch(for: store.sessions["Nutrition"]!, records: []), LaneStatusMatch.none,
                       "while the owned session is not listed the row shows no other")
    }

    private let row = AgentLane(id: "n", title: "Other", directory: URL(fileURLWithPath: "/x"), backendID: "claude-bg")
    private let backends: [String: any LaneBackend] = ["claude-bg": ClaudeBackgroundLaneBackend(id: "claude-bg")]

    func testOwnershipIsByIDNeverByName() {
        let left = DetachedSessions.unclaimed([found("aaaa1111", "Nutrition"), found("f4eced18", "renamed")],
                                              lanes: [row], backends: backends,
                                              ownedSessionIDs: ["n": .init(host: nil, agentID: "f4eced18")])
        XCTAssertEqual(left.map(\.session.agentID), ["aaaa1111"])
        XCTAssertEqual(DetachedSessions.unclaimed([found("f4eced18", "renamed")], lanes: [], backends: backends,
                                                  ownedSessionIDs: ["gone": .init(host: nil, agentID: "f4eced18")]).count, 1,
                       "a row that is not listed owns nothing")
    }

    func testTheSameIDOnAnotherHostIsStillShown() {
        let left = DetachedSessions.unclaimed([found("f4eced18", "Nutrition")], lanes: [row], backends: backends,
                                              ownedSessionIDs: ["n": .init(host: "hub-mac", agentID: "f4eced18")])
        XCTAssertEqual(left.count, 1, "the lane owns that id on another host, not this Mac's session")
    }

    func testAPrefixOnlyMatchIsStillShown() {
        let left = DetachedSessions.unclaimed([found("f4eced18", "Nutrition"), found("f4ec", "short")],
                                              lanes: [row], backends: backends,
                                              ownedSessionIDs: ["n": .init(host: nil, agentID: "f4e")])
        XCTAssertEqual(left.count, 2, "a bound id hides only the session whose short id is exactly it")
        let longer = DetachedSessions.unclaimed([found("f4ec", "short")], lanes: [row], backends: backends,
                                                ownedSessionIDs: ["n": .init(host: nil, agentID: "f4eced18")])
        XCTAssertEqual(longer.count, 1)
    }

    func testUnknownBindingsHideNothingAndAKnownBindingIsKept() {
        let store = store()
        store.received(.init(bindingsKnown: false), from: "hub-mac", hosts: hosts)
        store.received(found: bothSessions)
        XCTAssertNil(store.ownedSession(for: store.lanes[0]))
        XCTAssertEqual(foundTitles(store), ["Nutrition", "Personal - Nutrition"], "nothing is provably owned, so nothing is hidden")

        store.received(.init(bindings: ["Nutrition": "f4eced18"]), from: "hub-mac", hosts: hosts)
        XCTAssertEqual(foundTitles(store), ["Personal - Nutrition"])
        store.received(.init(bindingsKnown: false), from: "hub-mac", hosts: hosts)
        store.received(nil, from: "hub-mac", hosts: hosts)
        XCTAssertEqual(foundTitles(store), ["Personal - Nutrition"],
                       "a failed ask later keeps the last known binding, so the row does not flicker back")
    }

    func testNoFoundRowsUntilTheHostsFirstAnswer() {
        let store = store()
        XCTAssertTrue(store.awaitingFirstBindings, "the store asks its hosts as it starts")
        store.received(found: bothSessions)
        XCTAssertTrue(foundTitles(store).isEmpty, "a session that may be a lane's own is not shown before the bindings")
        store.received(.init(bindings: ["Nutrition": "f4eced18"]), from: "hub-mac", hosts: hosts)
        XCTAssertFalse(store.awaitingFirstBindings)
        XCTAssertEqual(foundTitles(store), ["Personal - Nutrition"])
    }
}
