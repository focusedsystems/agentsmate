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
}
