import Foundation
import Testing

@testable import AgentsMateUpdates

private let home = "/Users/test"

private func infer(_ resolved: String, cli: AgentCLI = .claude) -> AgentCLIInstall {
    AgentCLIInstallInference.infer(cli: cli, path: "/x/\(cli.rawValue)", resolvedPath: resolved, home: home)
}

@Suite struct InstallInferenceTests {
    @Test func cask() {
        let i = infer("/opt/homebrew/Caskroom/claude-code/2.1.0/claude")
        #expect(i.method == .homebrewCask)
        #expect(i.packageName == "claude-code")
        #expect(i.prefix == "/opt/homebrew")
    }

    @Test func formula() {
        let i = infer("/usr/local/Cellar/codex/0.9.0/bin/codex", cli: .codex)
        #expect(i.method == .homebrewFormula)
        #expect(i.packageName == "codex")
        #expect(i.prefix == "/usr/local")
    }

    @Test func npmGlobalScoped() {
        let i = infer("/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", cli: .codex)
        #expect(i.method == .npmGlobal)
        #expect(i.packageName == "@openai/codex")
        #expect(i.prefix == "/opt/homebrew")
    }

    @Test func npmGlobalInHome() {
        let i = infer("/Users/test/.npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js")
        #expect(i.method == .npmGlobal)
        #expect(i.prefix == "/Users/test/.npm-global")
    }

    @Test func nativeInstallers() {
        #expect(infer("/Users/test/.local/share/claude/versions/2.1.0").method == .claudeNative)
        #expect(infer("/Users/test/.claude/local/node_modules/.bin/claude").method == .claudeNative)
    }

    @Test func unknown() {
        #expect(infer("/Users/test/bin/claude").method == .unknown)
    }
}

private actor Calls {
    var list: [[String]] = []
    func add(_ call: [String]) { list.append(call) }
}

private final class Counter: @unchecked Sendable {
    private var items: [String]
    init(_ items: [String]) { self.items = items }
    func next() -> String { items.count > 1 ? items.removeFirst() : items[0] }
}

private func updater(
    present: Set<String>, resolved: [String: String] = [:],
    calls: Calls = Calls(), versions: [String] = ["1.0.0", "1.1.0"], exit: Int32 = 0
) -> AgentCLIUpdater {
    let counter = Counter(versions)
    return AgentCLIUpdater(
        home: home,
        runner: { exe, args, _ in
            await calls.add([exe] + args)
            if args == ["--version"] { return AgentCLIRunResult(exitCode: 0, stdout: "\(counter.next()) (Claude Code)\n") }
            return AgentCLIRunResult(exitCode: exit, stderr: exit == 0 ? "" : "Error: boom\n")
        },
        isExecutable: { present.contains($0) },
        realpath: { resolved[$0] ?? $0 })
}

@Suite struct CommandChoiceTests {
    private let u = AgentCLIUpdater(home: home)

    private func command(_ i: AgentCLIInstall) -> AgentCLIUpdateCommand? { u.command(for: i) }

    @Test func cask() {
        let c = command(infer("/opt/homebrew/Caskroom/claude-code/2/claude"))
        #expect(c?.displayString == "/opt/homebrew/bin/brew upgrade --cask claude-code")
        #expect(c?.environment["NONINTERACTIVE"] == "1")
    }

    @Test func formula() {
        let c = command(infer("/usr/local/Cellar/codex/1/bin/codex", cli: .codex))
        #expect(c?.displayString == "/usr/local/bin/brew upgrade codex")
    }

    @Test func npm() {
        let c = command(infer("/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", cli: .codex))
        #expect(c?.displayString == "/opt/homebrew/bin/npm install -g @openai/codex@latest")
    }

    @Test func native() {
        let i = AgentCLIInstall(
            cli: .claude, path: "/Users/test/.local/bin/claude",
            resolvedPath: "/Users/test/.local/share/claude/v", method: .claudeNative)
        #expect(command(i)?.displayString == "/Users/test/.local/bin/claude update")
    }

    @Test func unknownHasNoCommand() {
        #expect(command(infer("/Users/test/bin/claude")) == nil)
    }
}

@Suite struct CheckAndUpdateTests {
    private static let brewResolved = ["/opt/homebrew/bin/claude": "/opt/homebrew/Caskroom/claude-code/1.0.0/claude"]
    private static let brewPresent: Set<String> = ["/opt/homebrew/bin/claude", "/opt/homebrew/bin/brew"]

    @Test func absentCLIIsNotInstalledAndNothingRuns() async {
        let calls = Calls()
        let result = await updater(present: [], calls: calls).checkAndUpdate([.claude, .codex])
        #expect(result.allSatisfy { !$0.installed && $0.message == "Not installed" })
        #expect(await calls.list.isEmpty)
    }

    @Test func updatesThroughBrew() async {
        let calls = Calls()
        let u = updater(present: Self.brewPresent, resolved: Self.brewResolved, calls: calls)
        let result = await u.checkAndUpdate([.claude])
        #expect(result[0].message == "Updated 1.0.0 → 1.1.0")
        #expect(result[0].lastUpdated != nil)
        #expect(await calls.list.contains(["/opt/homebrew/bin/brew", "upgrade", "--cask", "claude-code"]))
    }

    @Test func upToDate() async {
        let u = updater(present: Self.brewPresent, resolved: Self.brewResolved, versions: ["1.0.0"])
        #expect(await u.checkAndUpdate([.claude])[0].message == "Up to date")
    }

    @Test func failureIsReported() async {
        let u = updater(present: Self.brewPresent, resolved: Self.brewResolved, exit: 1)
        #expect(await u.checkAndUpdate([.claude])[0].message == "Update failed: Error: boom")
    }

    @Test func unknownMethodRunsNoUpdate() async {
        let calls = Calls()
        let u = updater(present: ["/Users/test/bin/claude"], calls: calls)
        let u2 = AgentCLIUpdater(
            home: home, searchDirectories: ["/Users/test/bin"], runner: u.runner,
            isExecutable: u.isExecutable, realpath: u.realpath)
        let result = await u2.checkAndUpdate([.claude])
        #expect(result[0].installed && result[0].method == .unknown)
        #expect(await calls.list == [["/Users/test/bin/claude", "--version"]])
    }

    @Test func versionParsing() {
        #expect(AgentCLIUpdater.parseVersion("2.1.4 (Claude Code)\n") == "2.1.4")
        #expect(AgentCLIUpdater.parseVersion("codex-cli 0.46.0") == "0.46.0")
    }
}

@Suite struct StateTests {
    @Test func staleness() {
        let now = Date()
        #expect(AgentCLIUpdateState().isStale(interval: 60, now: now))
        #expect(!AgentCLIUpdateState(lastRun: now.addingTimeInterval(-30)).isStale(interval: 60, now: now))
        #expect(AgentCLIUpdateState(lastRun: now.addingTimeInterval(-61)).isStale(interval: 60, now: now))
    }

    @Test func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsmate-\(UUID().uuidString)/state.json")
        var state = AgentCLIUpdateState()
        state.merge(
            [AgentCLIStatus(cli: .codex, installed: true, version: "1.0", message: "Up to date")],
            ranAt: Date(timeIntervalSince1970: 100))
        try state.save(to: url)
        #expect(AgentCLIUpdateState.load(from: url) == state)
    }
}
