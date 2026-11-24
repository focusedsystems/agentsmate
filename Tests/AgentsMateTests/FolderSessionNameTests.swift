import XCTest
@testable import AgentsMate

final class FolderSessionNameTests: XCTestCase {
    private let root = "/w/AzDevOps"

    private func row(_ path: String, id: String? = nil) -> AgentLane {
        AgentLane(id: id ?? "row:" + path, title: (path as NSString).lastPathComponent,
                  directory: URL(fileURLWithPath: path, isDirectory: true), backendID: "codex", isClosable: false)
    }

    private func codex() -> CommandLaneBackend {
        .tmuxLane(id: "codex", displayName: "Codex", command: "codex-remote", statusAgent: "codex", variantFlag: "-n",
                  tmuxSessions: TmuxLaneSessions(prefixes: ["cx-"], sessionName: TmuxLaneSessions.folderSessionName(prefix: "cx-")))
    }

    private func found(_ name: String, _ folder: String) -> DetachedSessions.Found {
        .init(backendID: "codex", session: DiscoveredSession(kind: "tmux", name: name, directory: folder))
    }

    func testNameFollowsTheWrapper() {
        let name = TmuxLaneSessions.folderSessionName(prefix: "cx-")
        XCTAssertEqual(name(row("/w/AzDevOps")), "cx-azdevops")
        XCTAssertEqual(name(row("/w/Some Repo.v2")), "cx-some-repo-v2")
        var second = row("/w/Midpoint")
        second.variant = "2"
        XCTAssertEqual(name(second), "cx-midpoint-2")
        XCTAssertEqual(TmuxLaneSessions.folderSessionName()(row("/w/Cloud")), "cloud")
    }

    func testARowTakesItsOwnSessionByNameAndASecondLaneInTheFolderGetsItsOwnRow() {
        let rows = [row("\(root)/Projects"), row(root), row("\(root)/Identity/Midpoint"), row("\(root)/Cloud/Vantage")]
        let sessions = [
            found("cx-projects", "\(root)/Projects"), found("cx-azdevops", root),
            found("cx-midpoint", "\(root)/Identity/Midpoint"), found("cx-midpoint-2", "\(root)/Identity/Midpoint"),
            found("cx-vantage", "\(root)/Cloud/Vantage"), found("cx-vantage-2", "\(root)/Cloud/Vantage"),
        ]
        let left = DetachedSessions.unclaimed(sessions, lanes: rows, backends: ["codex": codex()])
        XCTAssertEqual(Set(left.map(\.session.name)), ["cx-midpoint-2", "cx-vantage-2"],
                       "the folder row of the root does not take its children's sessions, and a second lane shows apart")
    }

    func testAFolderRowDoesNotTakeASessionInAChildFolder() {
        let rows = [row(root)]
        let left = DetachedSessions.unclaimed([found("cx-projects", "\(root)/Projects")], lanes: rows,
                                              backends: ["codex": codex()])
        XCTAssertEqual(left.map(\.session.name), ["cx-projects"])
    }
}
