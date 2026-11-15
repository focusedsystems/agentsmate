import Foundation

/// The last known state of one CLI.
public struct AgentCLIStatus: Codable, Equatable, Sendable, Identifiable {
    public var cli: AgentCLI
    public var installed: Bool
    public var path: String?
    public var method: AgentCLIInstallMethod
    public var version: String?
    public var lastChecked: Date?
    public var lastUpdated: Date?
    public var message: String

    public var id: String { cli.rawValue }

    public init(
        cli: AgentCLI, installed: Bool = false, path: String? = nil,
        method: AgentCLIInstallMethod = .unknown, version: String? = nil,
        lastChecked: Date? = nil, lastUpdated: Date? = nil, message: String = "Not checked yet"
    ) {
        self.cli = cli
        self.installed = installed
        self.path = path
        self.method = method
        self.version = version
        self.lastChecked = lastChecked
        self.lastUpdated = lastUpdated
        self.message = message
    }
}

/// Everything the updater remembers between launches.
public struct AgentCLIUpdateState: Codable, Equatable, Sendable {
    public var statuses: [AgentCLIStatus]
    public var lastRun: Date?

    public init(statuses: [AgentCLIStatus] = [], lastRun: Date? = nil) {
        self.statuses = statuses
        self.lastRun = lastRun
    }

    public func status(for cli: AgentCLI) -> AgentCLIStatus? {
        statuses.first { $0.cli == cli }
    }

    /// True when no run is recorded or the last one is at least `interval` seconds old.
    public func isStale(interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }

    /// Replaces or adds statuses, keeping `lastUpdated` from the old entry when the new one has none.
    public mutating func merge(_ new: [AgentCLIStatus], ranAt: Date) {
        for var status in new {
            if let i = statuses.firstIndex(where: { $0.cli == status.cli }) {
                if status.lastUpdated == nil { status.lastUpdated = statuses[i].lastUpdated }
                statuses[i] = status
            } else {
                statuses.append(status)
            }
        }
        lastRun = ranAt
    }

    public static func load(from url: URL) -> AgentCLIUpdateState {
        guard let data = try? Data(contentsOf: url) else { return AgentCLIUpdateState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AgentCLIUpdateState.self, from: data)) ?? AgentCLIUpdateState()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
