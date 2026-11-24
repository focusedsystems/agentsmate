import XCTest
@testable import AgentsMateStatus

private func row(_ id: String, state: DisplayedExport.State = .working, session: String? = nil, attached: String? = nil,
                 tmux: String? = nil, host: String? = "host-a") -> DisplayedExport.Row {
    DisplayedExport.Row(section: "Group", title: id, laneID: id, backend: tmux == nil ? "claude-bg" : "tmux", agent: "claude",
                        sessionID: session, attachedSessionID: attached, sessionName: tmux, host: host, folder: "/work/\(id)",
                        state: state)
}

private func export(rows: [DisplayedExport.Row] = [], cards: [DisplayedExport.Row] = []) -> DisplayedExport {
    DisplayedExport(app: .init(bundleID: "com.example.app", version: "1", build: "2"), rows: rows, allAgents: cards)
}

private func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("displayed-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

final class DisplayedSchemaTests: XCTestCase {
    func testEncodesTheSchemaWithExplicitNulls() throws {
        var value = export(rows: [row("one", session: "ab12cd34", attached: "ab12cd34")], cards: [row("one")])
        value.writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
        value.counts = .init(needsYou: 1, working: 2, idleOrDone: 3)
        value.filter = .init(show: "active", statuses: ["running"], search: "api")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(Set(object.keys), ["schema_version", "app", "written_at", "last_discovery_finished_at", "filter",
                                          "counts", "rows", "all_agents"])
        XCTAssertTrue(object["last_discovery_finished_at"] is NSNull)
        let app = try XCTUnwrap(object["app"] as? [String: Any])
        XCTAssertEqual(Set(app.keys), ["bundle_id", "version", "build", "agentsmate_commit"])
        XCTAssertTrue(app["agentsmate_commit"] is NSNull)
        let filter = try XCTUnwrap(object["filter"] as? [String: Any])
        XCTAssertEqual(filter["show"] as? String, "active")
        XCTAssertEqual(filter["search"] as? String, "api")
        XCTAssertTrue(filter["sidebar_search"] is NSNull)
        XCTAssertEqual((object["counts"] as? [String: Int]), ["needs_you": 1, "working": 2, "idle_or_done": 3])
        let first = try XCTUnwrap((object["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["section", "title", "lane_id", "backend", "agent", "session_id", "attached_session_id",
                                         "session_name", "host", "folder", "state", "attached", "selected", "is_parallel",
                                         "is_top_level", "collapsed", "column"])
        XCTAssertTrue(first["session_name"] is NSNull)
        XCTAssertEqual(first["state"] as? String, "working")
        XCTAssertEqual(first["written_at"] as? String, nil)
        XCTAssertEqual(object["written_at"] as? String, "2023-11-14T22:13:20Z")
    }

    func testRoundTripsAndEveryStateNameIsSpelledAsDocumented() throws {
        XCTAssertEqual(DisplayedExport.State.allCases.map(\.rawValue),
                       ["active", "working", "needs_you", "idle", "not_attached", "stopped"])
        let value = export(rows: DisplayedExport.State.allCases.map { row($0.rawValue, state: $0) })
        let back = try JSONDecoder.displayed.decode(DisplayedExport.self, from: value.encoded())
        XCTAssertEqual(back, value)
    }

    func testTheStateFolderFollowsXDGWhenItIsAbsolute() {
        XCTAssertEqual(DisplayedExport.standardURL(bundleID: "com.example.app", environment: ["XDG_STATE_HOME": "/x/state"]).path,
                       "/x/state/agentsmate/com.example.app/displayed.json")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for env in [[:], ["XDG_STATE_HOME": ""], ["XDG_STATE_HOME": "relative/state"]] as [[String: String]] {
            XCTAssertEqual(DisplayedExport.standardURL(bundleID: "com.example.app", environment: env).path,
                           home + "/.local/state/agentsmate/com.example.app/displayed.json")
        }
        XCTAssertEqual(DisplayedExport.directory(bundleID: "../evil/id", environment: ["XDG_STATE_HOME": "/s"]).path,
                       "/s/agentsmate/.._evil_id".replacingOccurrences(of: "/.._", with: "/_.._"))
    }

    func testWritesAPrivateFileInAPrivateFolderAndReplacesItWhole() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("com.example.app/displayed.json")
        try DisplayedExport.write(try export(rows: [row("one")]).encoded(), to: url)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(mode(url.deletingLastPathComponent()), 0o700)
        try DisplayedExport.write(try export(rows: [row("two"), row("three")]).encoded(), to: url)
        XCTAssertEqual(DisplayedExport.load(url)?.rows.map(\.laneID), ["two", "three"])
        XCTAssertEqual(mode(url), 0o600)
        let left = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["displayed.json"], "the temporary file is renamed away, none is left behind")
    }

    func testAFileOfAnotherSchemaOrNoFileReadsAsNil() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(DisplayedExport.load(root.appendingPathComponent("none.json")))
        let url = root.appendingPathComponent("d.json")
        try Data(#"{"schema_version": 2}"#.utf8).write(to: url)
        XCTAssertNil(DisplayedExport.load(url))
    }
}

private extension JSONDecoder {
    static var displayed: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

final class DisplayedCompareTests: XCTestCase {
    private func snapshot(_ sessions: [[String: Any]], host: String = "host-a") throws -> LiveSessionSnapshot {
        let now = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "generated": now, "hosts": [host: ["seen": now, "sessions": sessions]]])
        return try XCTUnwrap(LiveSessionSnapshot.decode(data))
    }

    private func entry(_ id: String, kind: String = "tmux", name: String? = nil, folder: String = "/work/one",
                       state: String = "working", agentID: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["id": id, "kind": kind, "name": name ?? id, "folder": folder, "state": state]
        if let agentID { d["agentId"] = agentID }
        return d
    }

    func testListsSessionsNoRowShowsAndRowsClaimingWhatIsNotRunning() throws {
        let shown = export(rows: [row("a", tmux: "lane-a"), row("b", session: "bbbb0001"), row("ghost", tmux: "lane-ghost"),
                                  row("sleeping", state: .idle, tmux: "lane-zzz")])
        let snap = try snapshot([entry("tmux:lane-a", name: "lane-a"),
                                 entry("claude-bg:bbbb0001", kind: "background", name: "Work", agentID: "bbbb0001"),
                                 entry("tmux:lane-hidden", name: "lane-hidden", folder: "/work/hidden"),
                                 entry("tmux:lane-old", name: "lane-old", state: "done")])
        let result = DisplayedComparison.compare(shown, snapshot: snap)
        XCTAssertEqual(result.notShown.map(\.id), ["tmux:lane-hidden"], "a finished session is not expected on screen")
        XCTAssertEqual(result.shownButNotLive.map(\.laneID), ["ghost"], "an idle row claims nothing")
        XCTAssertFalse(result.scopeEvaluated)
        XCTAssertFalse(result.isClean)
    }

    func testAScopeLimitsWhatCountsAsMissingAndMatchesNeverCrossHosts() throws {
        let shown = export(rows: [row("a", tmux: "lane-a", host: "host-b")])
        let snap = try snapshot([entry("tmux:lane-a", name: "lane-a"),
                                 entry("tmux:in", name: "in", folder: "/work/team/repo"),
                                 entry("tmux:out", name: "out", folder: "/elsewhere")])
        let result = DisplayedComparison.compare(shown, snapshot: snap, scopeFolders: ["/work/team"])
        XCTAssertEqual(result.notShown.map(\.id), ["tmux:in"])
        XCTAssertEqual(result.shownButNotLive.map(\.laneID), ["a"], "the same tmux name on another host is another session")
        XCTAssertTrue(result.scopeEvaluated)
    }

    func testAnAttachedIDOrACardCountsAsShown() throws {
        let shown = export(rows: [row("a", session: "aaaa0001", attached: "aaaa0002")], cards: [row("c", tmux: "lane-c")])
        let snap = try snapshot([entry("claude-bg:aaaa0002", kind: "background", agentID: "aaaa0002"), entry("tmux:lane-c", name: "lane-c")])
        XCTAssertTrue(DisplayedComparison.compare(shown, snapshot: snap).isClean)
    }

    func testTheCommandPrintsAndExitsByWhatItFound() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["XDG_STATE_HOME": root.path]
        let url = DisplayedExport.standardURL(bundleID: "com.example.app", environment: env)
        try DisplayedExport.write(try export(rows: [row("ghost", tmux: "lane-ghost")]).encoded(), to: url)
        let live = root.appendingPathComponent("live.json")
        let now = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "generated": now, "hosts": ["host-a": [
            "seen": now, "sessions": [entry("tmux:lane-x", name: "lane-x")]]]])
        FileManager.default.createFile(atPath: live.path, contents: data, attributes: [.posixPermissions: 0o600])

        var out = "", err = ""
        var status = DisplayedCommand.run(["--app", "com.example.app"], environment: env, out: { out += $0 }, err: { err += $0 })
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("rows (1):") && out.contains("ghost"), out)

        out = ""
        status = DisplayedCommand.run(["--compare", live.path], environment: env, out: { out += $0 }, err: { err += $0 })
        XCTAssertEqual(status, 1, "one app only, so --app can be left out")
        XCTAssertTrue(out.contains("tmux:lane-x"), out)
        XCTAssertTrue(out.contains("shown as running, not in the snapshot (1)"), out)

        out = ""
        status = DisplayedCommand.run(["--json", "--compare", live.path], environment: env, out: { out += $0 }, err: { err += $0 })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let compare = try XCTUnwrap(object["compare"] as? [String: Any])
        XCTAssertEqual((compare["not_shown"] as? [[String: Any]])?.first?["id"] as? String, "tmux:lane-x")
        XCTAssertEqual((compare["shown_but_not_live"] as? [[String: Any]])?.first?["lane_id"] as? String, "ghost")

        status = DisplayedCommand.run(["--app", "com.example.none"], environment: env, out: { _ in }, err: { err += $0 })
        XCTAssertEqual(status, 2)
        XCTAssertTrue(err.contains("cannot read"), err)
    }
}
