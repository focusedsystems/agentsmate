import XCTest
@testable import AgentsMate

@MainActor
final class DuplicateBackendTests: XCTestCase {
    private func codexRemote() -> CommandLaneBackend {
        .tmuxLane(id: "app.codex", displayName: "Codex (tmux)", command: "codex-remote", statusAgent: "codex",
                  variantFlag: "-n",
                  tmuxSessions: TmuxLaneSessions(prefixes: ["cx-"], sessionName: TmuxLaneSessions.folderSessionName(prefix: "cx-")))
    }

    private func claudeRemote() -> CommandLaneBackend {
        .tmuxLane(id: "app.claude", displayName: "Claude (tmux)", command: "claude-remote", statusAgent: "claude",
                  variantFlag: "-n", tmuxSessions: TmuxLaneSessions(prefixes: [], sessionName: TmuxLaneSessions.folderSessionName()))
    }

    private func store() -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        let store = AgentLaneStore(configuration: config,
                                   backends: [codexRemote(), claudeRemote(), CommandLaneBackend(id: "app.hub", displayName: "Hub agents",
                                                                                                 command: "hub-agents")],
                                   statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-duplicate-\(UUID().uuidString)")!)
        var hub = AgentLane(id: "hub", title: "Hub", backendID: "app.hub")
        hub.accessory = .init(symbol: "cpu", label: "Hub agents")
        store.sync(lanes: [AgentLane(id: "row", title: "Midpoint", directory: URL(fileURLWithPath: "/w/Midpoint"),
                                     backendID: "app.codex"), hub])
        return store
    }

    func testAnAccessoryLanesBackendIsNeverOffered() {
        let store = store()
        XCTAssertEqual(store.availableBackends.map(\.displayName), ["Claude (tmux)", "Codex (tmux)"])
        XCTAssertNotNil(store.backend(id: "app.hub"), "still registered, so the lane itself runs")
        store.detachAll()
    }

    func testDuplicatingACodexLaneStartsTheNextCodexRemoteSessionAndBindsItByName() throws {
        let store = store()
        let copy = try XCTUnwrap(store.duplicate("row", focus: false))
        XCTAssertEqual(copy.lane.backendID, "app.codex", "a codex-remote lane duplicates onto codex-remote")
        XCTAssertEqual(copy.lane.variant, "2")
        let backend = try XCTUnwrap(store.backend(id: copy.lane.backendID) as? CommandLaneBackend)
        XCTAssertEqual(backend.sessionName(for: copy.lane), "cx-midpoint-2")
        XCTAssertEqual(backend.sessionName(for: store.lanes[0]), "cx-midpoint")
        let launch = backend.launch(for: copy.lane, shell: "/bin/zsh")
        XCTAssertTrue(launch.arguments.joined(separator: " ").contains("codex-remote -n '2'"), "\(launch.arguments)")

        let third = try XCTUnwrap(store.duplicate("row", backendID: "app.codex", focus: false))
        XCTAssertEqual(backend.sessionName(for: third.lane), "cx-midpoint-3", "the next free number")
        XCTAssertEqual(try XCTUnwrap(store.duplicate("row", backendID: "app.claude", focus: false)).lane.variant, nil,
                       "another backend in the folder starts at its own first session")
        store.detachAll()
    }
    private func storeWithClaudeBackground(host: String?) -> AgentLaneStore {
        var background = ClaudeBackgroundLaneBackend(id: "app.bg", claude: "/usr/bin/false")
        background.localHostNames = ["this-mac"]
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        let store = AgentLaneStore(configuration: config, backends: [codexRemote(), background], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-duplicate-\(UUID().uuidString)")!)
        store.liveSelfNameOverride = "this-mac"
        var row = AgentLane(id: "row", title: "Midpoint", directory: URL(fileURLWithPath: "/w/Midpoint"), backendID: "app.codex")
        row.host = host
        store.sync(lanes: [row])
        return store
    }

    func testDuplicatingAsClaudeBackgroundOnThisMacStartsANewSession() throws {
        for host in [nil, "this-mac", "THIS-MAC"] {
            let store = storeWithClaudeBackground(host: host)
            XCTAssertTrue(store.canDuplicate("row", backendID: "app.bg"))
            let copy = try XCTUnwrap(store.duplicate("row", backendID: "app.bg", focus: false), "host \(host ?? "nil")")
            XCTAssertTrue(copy.lane.startsNewSession)
            XCTAssertEqual(copy.lane.sessionName, "Midpoint 2")
            XCTAssertNil(copy.lane.host, "a lane on this Mac carries no host")
            let backend = try XCTUnwrap(store.backend(id: "app.bg") as? ClaudeBackgroundLaneBackend)
            XCTAssertEqual(backend.resolution(for: copy.lane), .none)
            let line = backend.launch(for: copy.lane, shell: "/bin/zsh").arguments.last ?? ""
            XCTAssertTrue(line.contains("--bg"), line)
            XCTAssertFalse(line.contains("nothing was attached"), line)
            store.detachAll()
        }
    }

    func testABackgroundLaneNamingThisMacIsNotRemote() {
        var backend = ClaudeBackgroundLaneBackend(id: "bg", claude: "/usr/bin/false")
        backend.localHostNames = ["this-mac"]
        var lane = AgentLane(id: "a", title: "A", directory: URL(fileURLWithPath: "/w/a"), backendID: "bg")
        lane.startsNewSession = true
        lane.host = "this-mac"
        XCTAssertEqual(backend.resolution(for: lane), .none)
        lane.host = "other-mac"
        XCTAssertEqual(backend.resolution(for: lane), .elsewhere("other-mac"))
    }

    func testAClaudeBackgroundCopyOfARemoteLaneIsRefusedUpFront() {
        let store = storeWithClaudeBackground(host: "other-mac")
        XCTAssertFalse(store.canDuplicate("row", backendID: "app.bg"))
        XCTAssertNil(store.duplicate("row", backendID: "app.bg", focus: false))
        XCTAssertEqual(store.lanes.count, 1)
        XCTAssertTrue(store.canDuplicate("row", backendID: "app.codex"), "other backends still copy")
        store.detachAll()
    }
}
