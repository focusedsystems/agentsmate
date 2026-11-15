import XCTest
@testable import AgentsMate

final class LaunchLineTests: XCTestCase {
    let prompt = URL(fileURLWithPath: "/p/brief.md")

    func testClaudeGetsPromptFileAndFolders() {
        XCTAssertEqual(LaunchLine.inject("claude --model opus", promptFile: prompt, directories: ["/a", "/a"]),
                       "claude --append-system-prompt-file '/p/brief.md' --add-dir '/a' --model opus")
        XCTAssertEqual(LaunchLine.inject("claude mcp list", promptFile: prompt), "claude mcp list")
        XCTAssertEqual(LaunchLine.inject("claude --version", promptFile: prompt), "claude --version")
    }

    func testCodexGetsInstructionsAndFoldersOnlyWhenWritable() {
        XCTAssertEqual(LaunchLine.inject("codex", promptFile: prompt, directories: ["/a"]),
                       "codex -c \"developer_instructions=$(cat '/p/brief.md')\"")
        XCTAssertEqual(LaunchLine.inject("codex --sandbox workspace-write", promptFile: nil, directories: ["/a"]),
                       "codex --add-dir '/a' --sandbox workspace-write")
        XCTAssertEqual(LaunchLine.inject("codex exec hi", promptFile: prompt), "codex exec hi")
    }

    func testOtherCommandsUntouched() {
        XCTAssertEqual(LaunchLine.inject("vim", promptFile: prompt), "vim")
        XCTAssertTrue(LaunchLine.isInstalled(""))
        XCTAssertTrue(LaunchLine.isInstalled("sh -c true"))
        XCTAssertFalse(LaunchLine.isInstalled("definitely-not-a-real-program-xyz"))
    }

    func testBackendAppliesInjectionAndResume() {
        let lane = AgentLane(id: "a", title: "A", directory: URL(fileURLWithPath: "/w"), backendID: "c")
        var backend = CommandLaneBackend(id: "c", displayName: "Claude", command: "claude", returnsToShell: true)
        backend.promptFile = prompt
        XCTAssertEqual(backend.launch(for: lane, shell: "/bin/zsh").arguments.last,
                       "claude --append-system-prompt-file '/p/brief.md'; exec '/bin/zsh' -l")
        XCTAssertEqual(backend.resumeLaunch(for: lane, shell: "/bin/zsh")?.arguments.last,
                       "claude --append-system-prompt-file '/p/brief.md' --continue || claude --append-system-prompt-file '/p/brief.md'; exec '/bin/zsh' -l")
    }
}

@MainActor
final class NewLaneTests: XCTestCase {
    func testNewLaneUsesCustomCommandAndLaunchBehavior() {
        let defaults = UserDefaults(suiteName: "agentsmate-new-\(UUID().uuidString)")!
        let store = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        defaults.set(AgentLaneStore.customBackendID, forKey: store.keys.newLaneBackend)
        defaults.set("echo hi", forKey: store.keys.newLaneCommand)
        let lane = store.openNewLane(in: URL(fileURLWithPath: "/tmp"), focus: false, open: false)
        XCTAssertEqual(lane?.lane.backendID, AgentLaneStore.customBackendID)
        XCTAssertEqual(lane?.lane.title, "echo · tmp")
        defaults.set(true, forKey: store.keys.openAtLaunch)
        let fresh = AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                                   backends: [CommandLaneBackend.shell], statusFeed: nil, defaults: defaults)
        fresh.performLaunchBehavior()
        XCTAssertEqual(fresh.lanes.count, 1)
        XCTAssertFalse(fresh.sessions[fresh.lanes[0].id]!.isStarted)
    }
}
