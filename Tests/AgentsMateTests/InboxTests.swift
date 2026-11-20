import XCTest
import AgentsMateStatus
@testable import AgentsMate

final class InboxSectionTests: XCTestCase {
    func testSections() {
        XCTAssertEqual(AgentInboxSection.of(status: .waitingForInput, unread: false), .askingYou)
        XCTAssertEqual(AgentInboxSection.of(status: .permissionRequested, unread: false), .askingYou)
        XCTAssertEqual(AgentInboxSection.of(status: .done, unread: true), .askingYou, "an unread notification asks")
        XCTAssertEqual(AgentInboxSection.of(status: .done, unread: false), .finished)
        XCTAssertEqual(AgentInboxSection.of(status: .idle, unread: false), .finished, "a polled idle lane is finished")
        XCTAssertNil(AgentInboxSection.of(status: .running, unread: false))
        XCTAssertNil(AgentInboxSection.of(status: .attached, unread: false))
        XCTAssertNil(AgentInboxSection.of(status: .notOpened, unread: false))
    }

    func testPullRequestLabels() {
        let github = URL(string: "https://github.com/owner/repo/pull/42")!
        let devops = URL(string: "https://devops.example.com/org/project/_git/repo/pullrequest/1234")!
        let files = URL(string: "https://github.com/owner/repo/pull/7/files")!
        XCTAssertEqual(PullRequestLinkLabel.number(of: github), 42)
        XCTAssertEqual(PullRequestLinkLabel.number(of: devops), 1234)
        XCTAssertEqual(PullRequestLinkLabel.title(of: files), "#7")
        XCTAssertEqual(PullRequestLinkLabel.title(of: URL(string: "https://example.com/review/abc")!), "abc")
    }
}

@MainActor
final class InboxStoreTests: XCTestCase {
    private func makeStore() -> AgentLaneStore {
        AgentLaneStore(configuration: .init(termProgram: "T", sessionFileDirectory: nil),
                       backends: [CommandLaneBackend.shell], statusFeed: nil,
                       defaults: UserDefaults(suiteName: "agentsmate-inbox-\(UUID().uuidString)")!)
    }

    private func lane(_ id: String) -> AgentLane {
        AgentLane(id: id, title: id.uppercased(), backendID: "shell")
    }

    func testUnreadAsksUntilMarkedRead() {
        let store = makeStore()
        store.sync(lanes: [lane("a"), lane("b")])
        let a = store.sessions["a"]!, b = store.sessions["b"]!
        for session in [a, b] {
            session.update(record: LaneStatus(agent: "claude", state: .running, lane: session.id, event: "UserPromptSubmit"))
            session.update(record: LaneStatus(agent: "claude", state: .done, lane: session.id, event: "Stop",
                                              updatedAt: Date(timeIntervalSinceNow: 1)))
        }
        XCTAssertEqual(store.inboxAsking.map(\.id), ["a", "b"])
        XCTAssertTrue(store.inboxFinished.isEmpty)
        store.markRead("a")
        XCTAssertEqual(store.inboxAsking.map(\.id), ["b"])
        XCTAssertEqual(store.inboxFinished.map(\.id), ["a"])
        store.markAllRead()
        XCTAssertTrue(store.inboxAsking.isEmpty)
        XCTAssertEqual(store.inboxFinished.map(\.id), ["a", "b"])
        XCTAssertTrue(store.unreadLanes.isEmpty)
    }

    func testAttachInBackgroundKeepsSelectionAndFocus() {
        let store = makeStore()
        store.sync(lanes: [lane("a"), lane("b")])
        XCTAssertEqual(store.selectedID, "a")
        store.attachInBackground("b")
        let b = store.sessions["b"]!
        XCTAssertTrue(b.isAttached)
        XCTAssertFalse(b.wantsFocus)
        XCTAssertEqual(store.selectedID, "a")
        XCTAssertFalse(store.canGoBack, "a background attach is not a visit")
        store.detachAll()
    }

    func testPullRequestHook() {
        let store = makeStore()
        var opened: [URL] = []
        store.onOpenPullRequest = { opened.append($0) }
        let url = URL(string: "https://github.com/owner/repo/pull/1")!
        store.openPullRequest(url)
        XCTAssertEqual(opened, [url])
    }
}
