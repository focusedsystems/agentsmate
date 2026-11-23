import XCTest
import AgentsMateStatus
@testable import AgentsMate

@MainActor
final class NewSessionAgentTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: "/work/repo")
    private func usage(_ agent: String, _ percent: Double) -> AgentUsage {
        AgentUsage(agent: agent, windows: [.init(label: "Week", percent: percent, resetsAt: Date().addingTimeInterval(3600))])
    }

    /// An app like those that offer all four agents through Reopen As.
    /// Configured to allow both agents in every folder unless told otherwise.
    private func makeStore(defaults: UserDefaults? = nil, allowed: Set<LaneAgentKind>? = Set(LaneAgentKind.allCases),
                           folders: (@Sendable (LaneAgentKind, URL) -> Bool)? = { _, _ in true }) -> (AgentLaneStore, UserDefaults) {
        let defaults = defaults ?? UserDefaults(suiteName: "agentsmate-new-session-\(UUID().uuidString)")!
        let backends = ["app", "cmd:claude-remote", "cmd:codex-remote", "cmd:claude", "cmd:codex"].map {
            CommandLaneBackend(id: $0, displayName: $0, command: "true")
        }
        let store = AgentLaneStore(configuration: .init(termProgram: "Test", reopenChoices: [
            .sameAgent(),
            LaneReopenChoice("Claude (remote)", backendID: "cmd:claude-remote", kind: .claudeRemote),
            LaneReopenChoice("Codex (remote)", backendID: "cmd:codex-remote", kind: .codexRemote),
            LaneReopenChoice("Claude (direct)", backendID: "cmd:claude", kind: .claudeDirect),
            LaneReopenChoice("Codex (direct)", backendID: "cmd:codex", kind: .codexDirect),
        ]), backends: backends, statusFeed: nil, defaults: defaults)
        store.configuration.allowedAgents = allowed
        store.configuration.agentAllowedForFolder = folders
        return (store, defaults)
    }

    func testTheAppsDefaultStandsUntilThePersonChooses() {
        let (store, defaults) = makeStore()
        let plan = store.newSessionPlan(preferring: "cmd:codex", in: Self.folder, usages: [])
        XCTAssertEqual(plan, NewSessionPlan(backendID: "cmd:codex", kind: .codexDirect))
        defaults.set("claudeRemote", forKey: store.keys.newSessionAgent)
        XCTAssertEqual(store.newSessionPlan(preferring: "cmd:codex", in: Self.folder, usages: []).backendID, "cmd:claude-remote")
        XCTAssertEqual(store.newSessionAgent, .claudeRemote)
        store.newSessionAgent = nil
        XCTAssertNil(defaults.string(forKey: store.keys.newSessionAgent))
    }

    func testTheKeysSitUnderTheAppsPrefix() {
        let keys = AgentsModeKeys(prefix: "app.")
        XCTAssertEqual(keys.newSessionAgent, "app.newSessionAgent")
        XCTAssertEqual(keys.switchesAgentNearLimit, "app.switchesAgentNearLimit")
        XCTAssertEqual(keys.agentSwitchThreshold, "app.agentSwitchThreshold")
    }

    func testNearTheLimitANewSessionStartsOnTheOtherAgentInTheSameMode() {
        let (store, _) = makeStore()
        store.newSessionAgent = .claudeRemote
        XCTAssertTrue(store.switchesAgentNearLimit, "on by default")
        XCTAssertEqual(store.agentSwitchThreshold, 90)
        let plan = store.newSessionPlan(in: Self.folder, usages: [usage("Claude", 93), usage("Codex", 20)])
        XCTAssertEqual(plan.backendID, "cmd:codex-remote")
        XCTAssertEqual(plan.kind, .codexRemote)
        XCTAssertEqual(plan.switchedFrom, .claudeRemote)
        XCTAssertEqual(plan.reason, "Claude at 93%, using Codex")

        store.newSessionAgent = .codexDirect
        XCTAssertEqual(store.newSessionPlan(in: Self.folder, usages: [usage("Codex", 95)]).backendID, "cmd:claude",
                       "unknown usage for the other agent does not stop the switch")
    }

    func testBelowTheThresholdOrUnknownKeepsTheChoice() {
        let (store, _) = makeStore()
        store.newSessionAgent = .claudeRemote
        XCTAssertEqual(store.newSessionPlan(in: Self.folder, usages: [usage("Claude", 89)]), NewSessionPlan(backendID: "cmd:claude-remote", kind: .claudeRemote))
        XCTAssertEqual(store.newSessionPlan(in: Self.folder, usages: []).backendID, "cmd:claude-remote", "unknown usage keeps the choice")
        store.agentSwitchThreshold = 85
        XCTAssertEqual(store.newSessionPlan(in: Self.folder, usages: [usage("Claude", 89)]).backendID, "cmd:codex-remote")
    }

    func testNoSwitchWhenTheOtherIsAsFullOrTheSettingIsOff() {
        let (store, _) = makeStore()
        store.newSessionAgent = .claudeRemote
        let full = store.newSessionPlan(in: Self.folder, usages: [usage("Claude", 93), usage("Codex", 97)])
        XCTAssertEqual(full.backendID, "cmd:claude-remote")
        XCTAssertEqual(full.reason, "Claude at 93%, Codex at 97%")
        store.switchesAgentNearLimit = false
        XCTAssertEqual(store.newSessionPlan(in: Self.folder, usages: [usage("Claude", 99)]).backendID, "cmd:claude-remote")
        store.switchesAgentNearLimit = true
        XCTAssertEqual(store.newSessionPlan(in: Self.folder, switchingOnUsage: false, usages: [usage("Claude", 99)]).backendID,
                       "cmd:claude-remote")
    }

    func testASpentAgentCountsAsFull() {
        let (store, _) = makeStore()
        store.newSessionAgent = .codexRemote
        let spent = AgentUsage(agent: "Codex", windows: [], note: "Limit reached",
                               resetsAt: Date().addingTimeInterval(3600))
        XCTAssertTrue(spent.isDepleted)
        XCTAssertEqual(store.usagePercent(of: "codex", in: [spent]), 100)
        XCTAssertEqual(store.newSessionPlan(in: Self.folder, usages: [spent]).backendID, "cmd:claude-remote")
        let unknown = AgentUsage(agent: "Codex", windows: [], note: AgentUsage.unknownNote)
        XCTAssertNil(store.usagePercent(of: "codex", in: [unknown]))
    }

    func testOpenNewLaneFollowsThePlanButSessionsAlreadyOpenKeepTheirAgent() {
        let (store, _) = makeStore()
        store.newSessionAgent = .codexRemote
        let lane = store.openNewLane(in: URL(fileURLWithPath: "/tmp"), backendID: "cmd:claude", focus: false, open: false)
        XCTAssertEqual(lane?.backend.id, "cmd:codex-remote")
        store.newSessionAgent = .claudeDirect
        XCTAssertEqual(lane?.backend.id, "cmd:codex-remote", "an open session keeps its agent")
        let pinned = store.openNewLane(backendID: "app", focus: false, open: false, followsAgentChoice: false)
        XCTAssertEqual(pinned?.backend.id, "app")
    }

    func testBackendsWithoutReopenChoicesAreReadFromTheirCommand() {
        let defaults = UserDefaults(suiteName: "agentsmate-new-session-\(UUID().uuidString)")!
        let claude = CommandLaneBackend.tmuxLane(id: "app.claude", displayName: "Claude", command: "true", statusAgent: "claude")
        let codex = CommandLaneBackend.tmuxLane(id: "app.codex", displayName: "Codex", command: "true", statusAgent: "codex")
        let store = AgentLaneStore(configuration: .init(termProgram: "Test"), backends: [claude, codex, CommandLaneBackend.shell],
                                   statusFeed: nil, defaults: defaults)
        XCTAssertEqual(store.configuredNewLaneBackendID, "app.claude", "the first by name")
        store.defaultNewSessionBackendID = { "app.codex" }
        XCTAssertEqual(store.agentKind(ofBackend: "app.claude"), .claudeRemote)
        XCTAssertNil(store.agentKind(ofBackend: CommandLaneBackend.shell.id))
        XCTAssertEqual(store.configuredNewLaneBackendID, "app.codex", "the app's default, not the first by name")
        XCTAssertEqual(store.availableAgentKinds, [.codexRemote], "unconfigured: only the default's agent")
        store.configuration.allowedAgents = [.claude, .codex]
        store.configuration.agentAllowedForFolder = { _, _ in true }
        XCTAssertEqual(store.availableAgentKinds, [.claudeRemote, .codexRemote])
        store.newSessionAgent = .claudeDirect
        XCTAssertEqual(store.newSessionPlan(in: Self.folder, usages: []).backendID, "app.claude",
                       "no direct Claude here: the remote one")
        XCTAssertEqual(store.newSessionPlan(in: Self.folder, usages: [usage("Claude", 95)]).backendID, "app.codex")
    }

    func testAnUnconfiguredAppFailsClosed() {
        let (store, _) = makeStore(allowed: nil, folders: nil)
        XCTAssertFalse(store.canSwitchAgents)
        store.newSessionAgent = .codexRemote
        let plan = store.newSessionPlan(preferring: "cmd:claude-remote", in: Self.folder,
                                        usages: [usage("Claude", 95), usage("Codex", 5)])
        XCTAssertEqual(plan, NewSessionPlan(backendID: "cmd:claude-remote", kind: .claudeRemote),
                       "neither the saved Codex choice nor the switch moves it off the app's default")
        store.newSessionAgent = .claudeDirect
        XCTAssertEqual(store.newSessionPlan(preferring: "cmd:claude-remote", in: Self.folder, usages: []).backendID,
                       "cmd:claude", "the default's own agent in the other mode still applies")
        let (both, _) = makeStore(folders: nil)
        both.newSessionAgent = .claudeRemote
        XCTAssertEqual(both.newSessionPlan(preferring: "cmd:claude-remote", in: Self.folder,
                                           usages: [usage("Claude", 95)]).backendID, "cmd:claude-remote",
                       "both agents allowed but no folder predicate: no switch")
    }

    func testAnAppWithOneAgentNeverPicksOrSwitchesToTheOther() {
        let (store, _) = makeStore(allowed: [.claude])
        XCTAssertEqual(store.availableAgentKinds, [.claudeRemote, .claudeDirect], "the picker hides Codex")
        XCTAssertFalse(store.canSwitchAgents)
        store.newSessionAgent = .codexRemote
        XCTAssertEqual(store.newSessionPlan(preferring: "cmd:claude-remote", usages: []).backendID, "cmd:claude-remote",
                       "a saved Codex choice is ignored")
        store.newSessionAgent = .claudeRemote
        let plan = store.newSessionPlan(in: Self.folder, usages: [usage("Claude", 99), usage("Codex", 1)])
        XCTAssertEqual(plan, NewSessionPlan(backendID: "cmd:claude-remote", kind: .claudeRemote))
    }

    func testAFolderPredicateDecidesAndDoubtKeepsTheDefault() {
        let work = URL(fileURLWithPath: "/work/repo")
        let other = URL(fileURLWithPath: "/elsewhere/repo")
        let (store, _) = makeStore(folders: { agent, folder in agent == .claude || folder.path.hasPrefix("/work/") })
        store.newSessionAgent = .claudeRemote
        let full = [usage("Claude", 95), usage("Codex", 10)]
        XCTAssertEqual(store.newSessionPlan(in: work, usages: full).backendID, "cmd:codex-remote")
        XCTAssertEqual(store.newSessionPlan(in: other, usages: full).backendID, "cmd:claude-remote",
                       "Codex may not work there")
        XCTAssertEqual(store.newSessionPlan(preferring: "cmd:codex", usages: full).backendID, "cmd:codex",
                       "no folder: the app's default, not the choice or the switch")
        store.newSessionAgent = .codexRemote
        XCTAssertEqual(store.newSessionPlan(preferring: "cmd:claude", in: other, usages: []).backendID, "cmd:claude",
                       "a choice the folder does not allow keeps the app's default")
        let lane = store.openNewLane(in: work, backendID: "cmd:claude", focus: false, open: false)
        XCTAssertEqual(lane?.backend.id, "cmd:codex-remote")
    }
}
