import Foundation

/// The Macs (and other machines) that open agent apps or run lanes, as
/// `~/.config/agent-hosts/hosts.conf` lists them, and which one this is.
///
/// `hosts.conf` has one host per line, `#` starting a comment:
///
///     # name     role    platform
///     hub-mac    hub     mac
///     laptop     client  mac
///     mini-1     lane    mac
///
/// A name is an ssh host alias every machine can reach. `self` in the same
/// folder holds this machine's name. AgentsMate only reads these files;
/// with either missing, lanes stay per-Mac as before.
public struct AgentHosts: Equatable, Sendable {
    public enum Role: String, Sendable, CaseIterable {
        /// Holds the shared lane lists and runs lanes by default. Exactly one.
        case hub
        /// Can run lanes.
        case lane
        /// Opens apps and attaches; never runs lanes.
        case client
    }

    public struct Host: Equatable, Sendable, Identifiable {
        public var name: String
        public var role: Role
        public var platform: String?
        public var id: String { name }

        public init(name: String, role: Role, platform: String? = nil) {
            self.name = name
            self.role = role
            self.platform = platform
        }

        /// Whether a lane can be sent to run here.
        public var runsLanes: Bool { role != .client }
    }

    public var hosts: [Host]
    /// This machine's name, from `self`.
    public var selfName: String

    public init(hosts: [Host], selfName: String) {
        self.hosts = hosts
        self.selfName = selfName
    }

    /// `~/.config/agent-hosts`.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-hosts", isDirectory: true)
    }

    /// The registry in `directory`, or nil when `hosts.conf` or `self` is
    /// missing or empty, or no host is the hub.
    public static func load(from directory: URL = defaultDirectory) -> AgentHosts? {
        guard let conf = try? String(contentsOf: directory.appendingPathComponent("hosts.conf"), encoding: .utf8),
              let me = try? String(contentsOf: directory.appendingPathComponent("self"), encoding: .utf8) else { return nil }
        let selfName = me.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard !selfName.isEmpty else { return nil }
        let registry = AgentHosts(hosts: parse(conf), selfName: selfName)
        return registry.hub == nil ? nil : registry
    }

    /// The hosts in a `hosts.conf`. Lines with an unknown role, or a name
    /// that is not a plain ssh alias, are skipped.
    public static func parse(_ text: String) -> [Host] {
        var hosts: [Host] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2, isValidName(fields[0]), let role = Role(rawValue: fields[1].lowercased()),
                  !hosts.contains(where: { $0.name == fields[0] }) else { continue }
            hosts.append(Host(name: fields[0], role: role, platform: fields.count > 2 ? fields[2] : nil))
        }
        return hosts
    }

    /// A name safe to hand ssh as a destination and to put in an
    /// environment variable: letters, digits, `.`, `-` and `_`, not
    /// starting with `-`.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// The first host with role hub.
    public var hub: Host? { hosts.first { $0.role == .hub } }

    /// Whether this machine is the hub.
    public var isHub: Bool { hub?.name == selfName }

    /// The hosts a lane can run on, the hub first.
    public var laneHosts: [Host] {
        hosts.filter { $0.role == .hub } + hosts.filter { $0.role == .lane }
    }
}
