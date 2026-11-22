import Foundation

/// A set of lanes the person saved under a name: the sections and the lanes
/// they opened themselves, each with its folder, backend, name and section.
public struct LaneWorkspace: Codable, Equatable, Sendable, Identifiable {
    public struct Lane: Codable, Equatable, Sendable {
        /// The lane's ``AgentLane/id``, reused when it is opened again so its
        /// `$AGENTSMATE_LANE` never changes. Nil in files written before it
        /// was kept; such a lane gets a new id.
        public var id: String?
        public var title: String?
        public var directory: String?
        public var backendID: String
        public var section: String?
        public var pinned: Bool?
        /// A second (third, …) lane in the same folder; see ``AgentLane/variant``.
        public var variant: String?
        /// The session the lane attaches by name; see ``AgentLane/sessionName``.
        public var sessionName: String?
        /// The lane that was selected, in the restore snapshot.
        public var selected: Bool?
        /// See ``AgentLane/host``.
        public var host: String?
        /// The command and variant flag of a ``CommandLaneBackend`` that
        /// passes the folder, so the lane can be started without the app.
        public var command: String?
        public var variantFlag: String?

        public init(title: String? = nil, directory: String? = nil, backendID: String,
                    section: String? = nil, pinned: Bool? = nil, variant: String? = nil,
                    sessionName: String? = nil, selected: Bool? = nil, id: String? = nil,
                    host: String? = nil, command: String? = nil, variantFlag: String? = nil) {
            self.id = id
            self.host = host
            self.command = command
            self.variantFlag = variantFlag
            self.variant = variant
            self.sessionName = sessionName
            self.selected = selected
            self.title = title
            self.directory = directory
            self.backendID = backendID
            self.section = section
            self.pinned = pinned
        }
    }

    public var name: String
    public var sections: [String]
    public var lanes: [Lane]

    public var id: String { name }

    public init(name: String, sections: [String] = [], lanes: [Lane] = []) {
        self.name = name
        self.sections = sections
        self.lanes = lanes
    }
}

/// The workspaces file: hand-editable JSON the app points at. It holds the
/// saved workspaces, which one opens at launch, and the lanes that were open
/// at the last quit.
public struct LaneWorkspaceFile: Codable, Equatable, Sendable {
    public var workspaces: [LaneWorkspace] = []
    public var openAtLaunch: String?
    /// The lanes open at the last quit, reopened at the next launch.
    public var restore: LaneWorkspace?

    public init() {}

    public static func load(_ url: URL) throws -> LaneWorkspaceFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return LaneWorkspaceFile() }
        return try JSONDecoder().decode(LaneWorkspaceFile.self, from: Data(contentsOf: url))
    }

    public func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public var launchWorkspace: LaneWorkspace? {
        openAtLaunch.flatMap { name in workspaces.first { $0.name == name } }
    }
}

/// Turning a fresh launch line into one that resumes the agent's last
/// conversation in that folder, falling back to a fresh start.
public enum LaneResume {
    /// `claude …` → `claude --continue …`; `codex …` → `codex resume --last …`.
    /// Nil for anything else, for a command that is already a subcommand, and
    /// for wrappers that keep their own sessions.
    public static func command(for command: String) -> String? {
        let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let program = words.first else { return nil }
        let rest = Array(words.dropFirst())
        let name = (program as NSString).lastPathComponent
        if let next = rest.first, !next.hasPrefix("-") { return nil }
        switch name {
        case "claude":
            if rest.contains(where: { ["--continue", "-c", "--resume", "-r"].contains($0) }) { return nil }
            return ([program, "--continue"] + rest).joined(separator: " ")
        case "codex":
            return ([program, "resume", "--last"] + rest).joined(separator: " ")
        default:
            return nil
        }
    }
}
