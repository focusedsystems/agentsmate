import XCTest
import SwiftUI
@testable import AgentsMate
@testable import AgentsMateStatus

@MainActor
final class LaneBadgeTests: XCTestCase {
    private func store() -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        var far = TmuxLaneSessions(prefixes: ["lane-"])
        far.host = "user@far-mac"
        let backends: [any LaneBackend] = [
            CommandLaneBackend.tmuxLane(id: "tmux", displayName: "Claude", command: "true", statusAgent: "claude",
                                        tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"])),
            CommandLaneBackend.tmuxLane(id: "far", displayName: "Codex", command: "true", statusAgent: "codex",
                                        tmuxSessions: far),
            ClaudeBackgroundLaneBackend(id: "bg", claude: "/usr/bin/false"),
            CommandLaneBackend.shell,
        ]
        let store = AgentLaneStore(configuration: config, backends: backends, statusFeed: nil,
                                   defaults: UserDefaults(suiteName: "agentsmate-badges-\(UUID().uuidString)")!)
        store.liveSelfNameOverride = "this-mac"
        func lane(_ id: String, _ backend: String, host: String? = nil) -> AgentLane {
            var l = AgentLane(id: id, title: id, directory: URL(fileURLWithPath: "/w/" + id), backendID: backend)
            l.host = host
            return l
        }
        store.sync(lanes: [lane("a", "tmux"), lane("b", "far"), lane("c", "bg"), lane("d", "shell")])
        return store
    }

    func testBadgesComeFromTheBackendAndTheHost() throws {
        let store = store()
        func badges(_ id: String) throws -> LaneBadges {
            store.laneBadges(for: try XCTUnwrap(store.lanes.first { $0.id == id }))
        }
        XCTAssertEqual(try badges("a"), LaneBadges(hostKind: .local, hostName: "this-mac", runKind: .tmux, agent: "claude"))
        XCTAssertEqual(try badges("b").hostKind, .remote)
        XCTAssertEqual(try badges("b").runKind, .tmux)
        XCTAssertEqual(try badges("b").agent, "codex")
        XCTAssertEqual(try badges("c").runKind, .bg)
        XCTAssertEqual(try badges("c").agent, "claude")
        XCTAssertEqual(try badges("c").hostKind, .local)
        XCTAssertEqual(try badges("d"), LaneBadges(hostKind: .local, hostName: "this-mac", runKind: .terminal, agent: nil))
    }

    func testTheExportCarriesTheSameKinds() {
        let rows = store().displayedExport().rows
        XCTAssertEqual(rows.map(\.hostKind), ["local", "remote", "local", "local"])
        XCTAssertEqual(rows.map(\.runKind), ["tmux", "tmux", "bg", "terminal"])
        XCTAssertEqual(rows.map(\.agent), ["claude", "codex", "claude", nil])
    }

    func testTheExportFileUsesTheDocumentedKeys() throws {
        let export = DisplayedExport(app: .init(bundleID: "x"),
                                     rows: [.init(title: "T", laneID: "t", backend: "tmux", state: .idle,
                                                  hostKind: "remote", runKind: "bg")])
        let data = try JSONEncoder().encode(export)
        let row = try XCTUnwrap(((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["host_kind"] as? String, "remote")
        XCTAssertEqual(row["run_kind"] as? String, "bg")
        XCTAssertEqual(try JSONDecoder().decode(DisplayedExport.self, from: data), export)
        var old = row
        old["host_kind"] = nil
        old["run_kind"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: old)
        XCTAssertNil(try JSONDecoder().decode(DisplayedExport.Row.self, from: legacy).hostKind)
    }

    func testTheSpokenLabelNamesAgentHowAndWhere() {
        XCTAssertEqual(LaneBadges(hostKind: .remote, hostName: "mac-desktop", runKind: .bg, agent: "claude").summary,
                       "Claude · background · mac-desktop")
        XCTAssertEqual(LaneBadges(hostKind: .local, runKind: .terminal).summary, "Shell · terminal · this Mac")
        XCTAssertEqual(LaneBadges(hostKind: .local, runKind: .tmux, agent: "codex").agentName, "Codex")
        XCTAssertEqual(LaneBadges(hostKind: .local, runKind: .tmux, agent: "gemini").agentName, "Gemini")
        XCTAssertNil(LaneBadges.symbol(forAgent: nil))
    }

    private func png(of view: NSView, named name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // A build the shim sends to another Mac does not carry the variable,
        // and only .build comes back, so the default lives there.
        let dir = ProcessInfo.processInfo.environment["AGENTSMATE_RENDER_DIR"]
            ?? FileManager.default.currentDirectoryPath + "/.build/renders"
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func testRenderRows() throws {
        let samples: [(String, LaneBadges, String?)] = [
            ("Billing", LaneBadges(hostKind: .local, hostName: "this-mac", runKind: .tmux, agent: "claude"), "main"),
            ("Search service", LaneBadges(hostKind: .remote, hostName: "far-mac", runKind: .bg, agent: "claude"), "fix-index"),
            ("Importer", LaneBadges(hostKind: .remote, hostName: "far-mac", runKind: .tmux, agent: "codex"), "main"),
            ("Scratch", LaneBadges(hostKind: .local, hostName: "this-mac", runKind: .terminal, agent: nil), nil),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let rows = VStack(alignment: .leading, spacing: 4) {
                ForEach(samples.indices, id: \.self) { i in
                    let (title, badges, branch) = samples[i]
                    LaneRow(session: self.session(title, branch: branch), shortcutNumber: nil, isSplit: false, badges: badges)
                }
            }
            .padding(8).frame(width: 260, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: rows)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            try png(of: host, named: "lane-badges-\(scheme == .dark ? "dark" : "light").png")
        }
    }

    private func session(_ title: String, branch: String?) -> AgentLaneSession {
        let lane = AgentLane(id: title, title: title, directory: URL(fileURLWithPath: "/tmp/" + title), backendID: "shell")
        let session = AgentLaneSession(lane: lane, backend: CommandLaneBackend.shell)
        session.rowMetadata = LaneRowMetadata(branch: branch)
        return session
    }
}
