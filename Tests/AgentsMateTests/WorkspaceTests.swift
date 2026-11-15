import XCTest
@testable import AgentsMate

final class LaneResumeTests: XCTestCase {
    func testResumeRewrites() {
        XCTAssertEqual(LaneResume.command(for: "claude --model opus"), "claude --continue --model opus")
        XCTAssertEqual(LaneResume.command(for: "codex"), "codex resume --last")
        XCTAssertNil(LaneResume.command(for: "claude --continue"))
        XCTAssertNil(LaneResume.command(for: "codex exec hi"))
        XCTAssertNil(LaneResume.command(for: "my-lane-wrapper"))
    }

    func testCommandBackendResumesWithFallback() {
        let lane = AgentLane(id: "a", title: "A", directory: URL(fileURLWithPath: "/w"), backendID: "c")
        let backend = CommandLaneBackend(id: "c", displayName: "C", command: "claude")
        XCTAssertEqual(backend.resumeLaunch(for: lane, shell: "/bin/zsh")?.arguments.last, "claude --continue || claude")
        XCTAssertNil(CommandLaneBackend.tmuxLane(id: "t", displayName: "T", command: "claude", statusAgent: nil)
            .resumeLaunch(for: lane, shell: "/bin/zsh"))
    }
}

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testSaveOpenAndRestore() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let defaults = UserDefaults(suiteName: "agentsmate-ws-\(UUID().uuidString)")!
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, workspaceFile: file)
        let store = AgentLaneStore(configuration: config, backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        store.add(AgentLane(id: "x", title: "X", directory: URL(fileURLWithPath: "/tmp"), backendID: "shell",
                            isClosable: true, section: "Work"), open: false)
        store.rename("x", to: "Scratch")
        store.saveWorkspace(named: "Day")
        XCTAssertEqual(try LaneWorkspaceFile.load(file).workspaces.first?.lanes.first?.title, "Scratch")

        let other = AgentLaneStore(configuration: config, backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-ws2-\(UUID().uuidString)")!)
        other.reloadWorkspaces()
        other.open(workspace: other.workspaces.workspaces[0])
        XCTAssertEqual(other.lanes.count, 1)
        XCTAssertEqual(other.sessions[other.lanes[0].id]?.title, "Scratch")
        XCTAssertEqual(other.layout.section(of: other.lanes[0]), "Work")
        XCTAssertFalse(other.sessions[other.lanes[0].id]!.isStarted)
        other.open(workspace: other.workspaces.workspaces[0])
        XCTAssertEqual(other.lanes.count, 1, "an already open lane is not added twice")

        other.setOpenAtLaunch("Day")
        let third = AgentLaneStore(configuration: config, backends: [CommandLaneBackend.shell], statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-ws3-\(UUID().uuidString)")!)
        XCTAssertTrue(third.restoreAtLaunch())
        XCTAssertEqual(third.lanes.count, 1)
    }
}
