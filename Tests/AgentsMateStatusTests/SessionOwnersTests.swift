import XCTest
@testable import AgentsMateStatus

final class SessionOwnersTests: XCTestCase {
    private func temporaryFile() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("owners-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("agentsmate/session-owner.json")
    }

    private let keys = SessionOwners.Keys(sessionIDs: ["s1"], tmuxName: "lane-a", folder: "/work/repo")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAClaimIsReadBackAndTheLastClaimWins() {
        let file = temporaryFile()
        XCTAssertTrue(SessionOwners.claim(keys, app: "app.a", at: now, in: file))
        XCTAssertEqual(SessionOwners.load(file, now: now).owner(for: keys, now: now)?.app, "app.a")
        XCTAssertTrue(SessionOwners.claim(keys, app: "app.b", at: now.addingTimeInterval(5), in: file))
        XCTAssertEqual(SessionOwners.load(file, now: now.addingTimeInterval(5)).owner(for: keys, now: now.addingTimeInterval(5))?.app, "app.b")
    }

    func testTheFileIsPrivateAndItsFolderToo() throws {
        let file = temporaryFile()
        SessionOwners.claim(keys, app: "app.a", in: file)
        let mode = { (url: URL) in try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value }
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".tmp") }, "the temporary file is renamed away")
    }

    func testTwoSessionsKeepTheirOwnClaims() {
        let file = temporaryFile()
        let other = SessionOwners.Keys(sessionIDs: ["s2"])
        SessionOwners.claim(keys, app: "app.a", at: now, in: file)
        SessionOwners.claim(other, app: "app.b", at: now, in: file)
        let snapshot = SessionOwners.load(file, now: now)
        XCTAssertEqual(snapshot.owner(for: keys, now: now)?.app, "app.a")
        XCTAssertEqual(snapshot.owner(for: other, now: now)?.app, "app.b")
    }

    func testAFolderIsAKeyOnlyWhenNothingElseNamesTheSession() {
        XCTAssertEqual(SessionOwners.Keys(sessionIDs: [nil], tmuxName: nil, folder: "/w").all, ["/w"])
        XCTAssertEqual(SessionOwners.Keys(sessionIDs: ["a", "a", nil], tmuxName: "t", folder: "/w").all, ["a", "t"])
        XCTAssertTrue(SessionOwners.Keys().isEmpty)
    }

    func testACorruptFileCountsAsEmptyAndIsReplacedByTheNextClaim() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["", "not json", "[1,2]", "{\"s1\": 4}", "{\"s1\": {\"app\": \"\", \"at\": \"2026-01-01T00:00:00Z\"}}",
                     "{\"s1\": {\"app\": \"app.a\", \"at\": \"yesterday\"}}"] {
            try Data(text.utf8).write(to: file)
            chmod(file.path, 0o600)
            XCTAssertEqual(SessionOwners.load(file, now: now).entries, [:], text)
        }
        try Data("not json".utf8).write(to: file)
        chmod(file.path, 0o600)
        XCTAssertTrue(SessionOwners.claim(keys, app: "app.b", at: now, in: file))
        XCTAssertEqual(SessionOwners.load(file, now: now).owner(for: keys, now: now)?.app, "app.b")
    }

    func testOneBadEntryDoesNotHideTheGoodOnes() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = "{\"s1\": {\"app\": \"app.a\", \"at\": \"2027-01-15T08:00:00Z\"}, \"s2\": \"junk\"}"
        try Data(good.utf8).write(to: file)
        chmod(file.path, 0o600)
        let at = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
        XCTAssertEqual(SessionOwners.load(file, now: at).entries.keys.sorted(), ["s1"])
    }

    func testAFileOthersCanWriteIsIgnored() {
        let file = temporaryFile()
        SessionOwners.claim(keys, app: "app.a", at: now, in: file)
        XCTAssertEqual(SessionOwners.load(file, now: now).entries.count, 2)
        for mode: mode_t in [0o666, 0o664, 0o620, 0o602] {
            chmod(file.path, mode)
            XCTAssertEqual(SessionOwners.load(file, now: now).entries, [:], String(mode, radix: 8))
        }
        chmod(file.path, 0o644)
        XCTAssertEqual(SessionOwners.load(file, now: now).entries.count, 2, "readable by others is fine; writable is not")
    }

    func testASymlinkIsNotFollowed() throws {
        let file = temporaryFile()
        SessionOwners.claim(keys, app: "app.a", at: now, in: file)
        let link = file.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(SessionOwners.load(link, now: now).entries, [:])
    }

    func testAnOldClaimStopsCountingAndAnAncientOneIsDropped() {
        let file = temporaryFile()
        SessionOwners.claim(keys, app: "app.a", created: true, at: now, in: file)
        let later = now.addingTimeInterval(SessionOwners.ownerMaxAge + 60)
        let snapshot = SessionOwners.load(file, now: later)
        XCTAssertNil(snapshot.owner(for: keys, now: later))
        XCTAssertEqual(snapshot.creator(for: keys), "app.a", "the creator outlives the claim")
        XCTAssertEqual(SessionOwners.load(file, now: now.addingTimeInterval(SessionOwners.entryMaxAge + 60)).entries, [:])
        XCTAssertNil(SessionOwners.load(file, now: now.addingTimeInterval(-3600)).owner(for: keys, now: now.addingTimeInterval(-3600)),
                     "a claim from the future is not believed")
    }

    func testTheCreatorIsKeptWhenAnotherAppTakesOver() {
        let file = temporaryFile()
        SessionOwners.claim(keys, app: "app.a", created: true, at: now, in: file)
        SessionOwners.claim(keys, app: "app.b", at: now.addingTimeInterval(10), in: file)
        let snapshot = SessionOwners.load(file, now: now.addingTimeInterval(10))
        XCTAssertEqual(snapshot.owner(for: keys, now: now.addingTimeInterval(10))?.app, "app.b")
        XCTAssertEqual(snapshot.creator(for: keys), "app.a")
    }

    func testFallbackOrder() {
        let none = SessionOwners.Snapshot()
        let peers: () -> Set<String> = { ["app.c", "app.b"] }
        // A lane that is not shared is this app's, whatever the file says.
        let recorded = SessionOwners.Snapshot(entries: ["s1": .init(app: "app.z", at: now, createdBy: "app.y")])
        XCTAssertEqual(SessionOwners.decide(keys: keys, me: "app.m", isShared: false, snapshot: recorded, peers: peers, now: now),
                       .init(owner: "app.m", reason: .unshared))
        // The app the person last worked in.
        XCTAssertEqual(SessionOwners.decide(keys: keys, me: "app.m", isShared: true, snapshot: recorded, peers: peers, now: now),
                       .init(owner: "app.z", reason: .recorded))
        // No claim: the app that created it.
        let created = SessionOwners.Snapshot(entries: ["s1": .init(app: "app.z", at: now.addingTimeInterval(-SessionOwners.ownerMaxAge - 1), createdBy: "app.y")])
        XCTAssertEqual(SessionOwners.decide(keys: keys, me: "app.m", isShared: true, snapshot: created, peers: peers, now: now),
                       .init(owner: "app.y", reason: .creator))
        // Nothing at all: the lowest bundle id, this app's included.
        XCTAssertEqual(SessionOwners.decide(keys: keys, me: "app.m", isShared: true, snapshot: none, peers: peers, now: now),
                       .init(owner: "app.b", reason: .tieBreak))
        XCTAssertEqual(SessionOwners.decide(keys: keys, me: "app.a", isShared: true, snapshot: none, peers: peers, now: now),
                       .init(owner: "app.a", reason: .tieBreak))
        XCTAssertEqual(SessionOwners.decide(keys: keys, me: "app.m", isShared: true, snapshot: none, peers: { [] }, now: now).owner, "app.m")
    }

    func testAnOwnerThatIsNotRunningIsPassedOver() {
        let peers: () -> Set<String> = { ["app.c", "app.b"] }
        let entry = SessionOwners.Entry(app: "app.z", at: now, createdBy: "app.y")
        let snapshot = SessionOwners.Snapshot(entries: ["s1": entry])
        func decide(_ running: Set<String>) -> SessionOwners.Decision {
            SessionOwners.decide(keys: keys, me: "app.m", isShared: true, snapshot: snapshot, peers: peers,
                                 isRunning: { running.contains($0) }, now: now)
        }
        XCTAssertEqual(decide(["app.z", "app.y"]), .init(owner: "app.z", reason: .recorded))
        XCTAssertEqual(decide(["app.y", "app.b"]), .init(owner: "app.y", reason: .creator), "owner closed: the creator")
        XCTAssertEqual(decide(["app.c", "app.b"]), .init(owner: "app.b", reason: .tieBreak), "both closed: lowest running id")
        XCTAssertEqual(decide([]), .init(owner: "app.m", reason: .tieBreak), "nothing else running: this app")
    }

    func testPeersAreTheOtherAppsListingTheSession() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("peers-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let environment = ["XDG_STATE_HOME": home.path]
        for (app, session) in [("app.a", "s1"), ("app.b", "s1"), ("app.c", "s9")] {
            let row = DisplayedExport.Row(title: "t", laneID: "l", backend: "tmux", sessionID: session, state: .working)
            var export = DisplayedExport(app: .init(bundleID: app), rows: [row])
            export.writtenAt = Date()
            try DisplayedExport.write(try export.encoded(), to: DisplayedExport.standardURL(bundleID: app, environment: environment))
        }
        let index = SessionOwners.peerIndex(excluding: "app.a", environment: environment)
        XCTAssertEqual(index["s1"], ["app.b"])
        XCTAssertEqual(index["s9"], ["app.c"])
    }

    func testOwnerAppIsAdditiveInTheDisplayedExport() throws {
        let row = DisplayedExport.Row(title: "t", laneID: "l", backend: "tmux", state: .working, ownerApp: "app.a")
        let text = String(decoding: try DisplayedExport(app: .init(bundleID: "app.a"), rows: [row]).encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"owner_app\" : \"app.a\""))
        let old = text.replacingOccurrences(of: "\"owner_app\" : \"app.a\",", with: "").replacingOccurrences(of: ",\n      \"owner_app\" : \"app.a\"", with: "")
        XCTAssertFalse(old.contains("owner_app"))
        XCTAssertNil(try DisplayedExport.decoder.decode(DisplayedExport.self, from: Data(old.utf8)).rows.first?.ownerApp)
    }
}
