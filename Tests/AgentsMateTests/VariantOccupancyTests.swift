import XCTest
@testable import AgentsMate

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(String, [String])] = []
    func add(_ call: (String, [String])) { lock.lock(); all.append(call); lock.unlock() }
    var list: [(String, [String])] { lock.lock(); defer { lock.unlock() }; return all }
}

final class VariantOccupancyTests: XCTestCase {
    private func occupancy(status: Int32?, calls: Calls = Calls(), selfName: String? = "this-mac",
                           dirs: [String]? = nil) -> VariantOccupancy {
        VariantOccupancy(ledgerDirectories: dirs, selfName: selfName, environment: [:]) { executable, arguments, _ in
            calls.add((executable, arguments))
            return status
        }
    }

    func testALocalLaneIsProbedInAShellNotOverSSH() {
        let calls = Calls()
        XCTAssertTrue(occupancy(status: 0, calls: calls).isOccupied(backendID: "b", sessionName: "cx-munki-2", host: nil))
        XCTAssertFalse(occupancy(status: 1).isOccupied(backendID: "b", sessionName: "cx-munki-2", host: nil))
        _ = occupancy(status: 0, calls: calls).isOccupied(backendID: "b", sessionName: "cx-munki-2", host: "this-mac")
        XCTAssertEqual(calls.list.map(\.0), ["/bin/sh", "/bin/sh"], "a lane that names this Mac runs here")
        let line = calls.list[0].1.last ?? ""
        XCTAssertTrue(line.contains("has-session -t '=cx-munki-2'"), line)
    }

    func testARemoteLaneIsProbedOverSSHInBatchMode() {
        let calls = Calls()
        XCTAssertFalse(occupancy(status: 1, calls: calls).isOccupied(backendID: "b", sessionName: "cx-munki-2", host: "mini-1"))
        let call = calls.list[0]
        XCTAssertEqual(call.0, "/usr/bin/ssh")
        XCTAssertTrue(call.1.starts(with: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--", "mini-1"]), "\(call.1)")
    }

    func testAnUnreachableHostOrATimeoutCountsAsTaken() {
        XCTAssertTrue(occupancy(status: 255).isOccupied(backendID: "b", sessionName: "n", host: "mini-1"), "ssh failed")
        XCTAssertTrue(occupancy(status: nil).isOccupied(backendID: "b", sessionName: "n", host: "mini-1"), "timed out")
        XCTAssertTrue(occupancy(status: nil).isOccupied(backendID: "b", sessionName: "n", host: nil))
        XCTAssertTrue(occupancy(status: 1).isOccupied(backendID: "b", sessionName: "n", host: "bad host;rm"), "never handed to ssh")
    }

    func testTheProbeNamesTheLedgerFoldersAndSanitisesTheFileName() {
        let line = occupancy(status: 1, dirs: ["~/state/*-lane/lanes"]).shellLine(sessionName: "cx-my folder-2")
        XCTAssertTrue(line.contains("\"$HOME/state/*-lane/lanes\"/'cx-my_folder-2'"), line)
        let environment = VariantOccupancy(environment: ["AGENTSMATE_LEDGER_DIRS": "~/a:/b/c"], run: { _, _, _ in 1 })
        XCTAssertEqual(environment.ledgerDirectories, ["~/a", "/b/c"])
    }

    func testARealLedgerEntryAndAFreeNameAreTold() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("occ-\(UUID().uuidString)")
        let ledger = home.appendingPathComponent("lanes")
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        try "id".write(to: ledger.appendingPathComponent("zz-probe-2"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }
        let real = VariantOccupancy(ledgerDirectories: [ledger.path], tmux: "no-such-tmux", selfName: nil, environment: [:])
        XCTAssertTrue(real.isOccupied(backendID: "b", sessionName: "zz-probe-2", host: nil))
        XCTAssertFalse(real.isOccupied(backendID: "b", sessionName: "zz-probe-3", host: nil))
    }

    @MainActor
    func testTheStoreUsesTheProbeByDefaultAndAnAppCanOverrideIt() throws {
        var config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  sharedLanes: nil, liveSnapshotFile: nil, opensActiveOnly: false,
                                                  displayedExportFile: nil)
        XCTAssertNotNil(config.variantOccupied, "on by default")
        config.variantOccupied = nil
        XCTAssertNil(config.variantOccupied)
    }
}
