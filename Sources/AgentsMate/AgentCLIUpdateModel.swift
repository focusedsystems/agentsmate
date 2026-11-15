import AgentsMateUpdates
import Foundation

/// Keeps the agent CLIs current in the background and exposes their state to Settings.
@MainActor
public final class AgentCLIUpdateModel: ObservableObject {
    @Published public private(set) var state: AgentCLIUpdateState
    @Published public private(set) var isRunning = false
    /// Whether the app checks for and installs updates by itself. Saved in UserDefaults.
    @Published public var keepCurrent: Bool {
        didSet { defaults.set(keepCurrent, forKey: keepCurrentKey) }
    }

    public let clis: [AgentCLI]
    public var checkInterval: TimeInterval = 6 * 60 * 60
    public var initialDelay: TimeInterval = 20

    private let stateURL: URL
    private let keepCurrentKey: String
    private let defaults: UserDefaults
    private let updater: AgentCLIUpdater
    private var loop: Task<Void, Never>?

    public init(
        stateURL: URL,
        keepCurrentKey: String,
        clis: [AgentCLI] = AgentCLI.allCases,
        defaults: UserDefaults = .standard,
        updater: AgentCLIUpdater = AgentCLIUpdater()
    ) {
        self.stateURL = stateURL
        self.keepCurrentKey = keepCurrentKey
        self.clis = clis
        self.defaults = defaults
        self.updater = updater
        self.state = AgentCLIUpdateState.load(from: stateURL)
        self.keepCurrent = defaults.object(forKey: keepCurrentKey) as? Bool ?? true
    }

    /// True while the app updates the CLIs itself, so their own updaters should be off.
    public var managesUpdates: Bool { keepCurrent }

    /// Environment variables to give an agent process so it does not update itself.
    public func launchEnvironment(for cli: AgentCLI) -> [String: String] {
        guard managesUpdates else { return [:] }
        return cli == .claude ? ["DISABLE_AUTOUPDATER": "1"] : [:]
    }

    /// Extra arguments to give an agent process so it does not update itself.
    public func launchArguments(for cli: AgentCLI) -> [String] {
        guard managesUpdates else { return [] }
        return cli == .codex ? ["-c", "check_for_update_on_startup=false"] : []
    }

    public func status(for cli: AgentCLI) -> AgentCLIStatus? { state.status(for: cli) }

    /// Checks after `initialDelay`, then every `checkInterval`, skipping a run when the last one is recent.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var delay = self?.initialDelay ?? 20
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                if self.keepCurrent, self.state.isStale(interval: self.checkInterval) {
                    await self.updateNow()
                }
                delay = self.checkInterval
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func updateNow() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let results = await updater.checkAndUpdate(clis)
        state.merge(results, ranAt: Date())
        try? state.save(to: stateURL)
    }

    /// The command to copy for a CLI: its update command, or an npm install when it is absent or unknown.
    public func copyableCommand(for cli: AgentCLI) -> String {
        if let install = updater.locate(cli), let command = updater.command(for: install) {
            return command.displayString
        }
        return cli.installCommand
    }
}
