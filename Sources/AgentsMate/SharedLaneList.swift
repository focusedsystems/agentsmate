import Foundation

/// The lanes one app has open on every Mac, kept as one file on the hub
/// (`~/.local/state/agentsmate/<app id>/lanes.json`) so the app opened on
/// any Mac shows the same lanes, each attaching the same session.
///
/// A lane is known by its ``Lane/id`` alone, never its folder: two lanes in
/// one folder differ by id and ``Lane/variant``. Copies are merged lane by
/// lane, the newer ``Lane/updated`` winning, and a lane in ``closed`` with a
/// time at or after its `updated` stays closed, so a Mac that has not
/// synced for a while cannot bring it back. See `docs/shared-lanes.md`.
public struct SharedLaneList: Equatable, Sendable {
    public struct Lane: Equatable, Sendable {
        /// Reused forever; it is the lane's `$AGENTSMATE_LANE`.
        public var id: String
        public var title: String?
        /// The folder, with the home folder written `~`.
        public var directory: String?
        public var backendID: String
        /// The wrapper a ``CommandLaneBackend`` that passes the folder runs,
        /// so a lane can be started without the app.
        public var command: String?
        /// That backend's ``CommandLaneBackend/variantFlag``.
        public var variantFlag: String?
        /// Nil for the first lane in a folder.
        public var variant: String?
        /// The host the lane runs on; nil is the hub.
        public var host: String?
        public var section: String?
        public var pinned: Bool?
        /// The icon the person chose, in ``LaneIcon/stringValue`` form.
        public var icon: String?
        /// The colour the person chose, as `#RRGGBB`.
        public var tint: String?
        /// The session the lane attaches by name; see ``AgentLane/sessionName``.
        public var sessionName: String?
        /// The session's short id; see ``AgentLane/agentSessionID``.
        public var agentSessionID: String?
        /// True for a row the app itself lists (one its own registry
        /// defines, or a session found running) that this entry only names,
        /// pins, colours or files. It never makes a row on another Mac.
        public var overlay: Bool?
        public var order: Int
        public var updated: Date

        public init(id: String, title: String? = nil, directory: String? = nil, backendID: String,
                    command: String? = nil, variantFlag: String? = nil, variant: String? = nil,
                    host: String? = nil, section: String? = nil, pinned: Bool? = nil,
                    icon: String? = nil, tint: String? = nil, sessionName: String? = nil,
                    agentSessionID: String? = nil, overlay: Bool? = nil,
                    order: Int = 0, updated: Date = SharedLaneList.now()) {
            self.icon = icon
            self.tint = tint
            self.sessionName = sessionName
            self.agentSessionID = agentSessionID
            self.overlay = overlay
            self.id = id
            self.title = title
            self.directory = directory
            self.backendID = backendID
            self.command = command
            self.variantFlag = variantFlag
            self.variant = variant
            self.host = host
            self.section = section
            self.pinned = pinned
            self.order = order
            self.updated = updated
        }

        /// Whether two copies say the same thing, apart from where the lane
        /// sits in the list and when it was last changed.
        public func sameContent(as other: Lane) -> Bool {
            var a = self, b = other
            a.order = 0; b.order = 0
            a.updated = .distantPast; b.updated = .distantPast
            return a == b
        }
    }

    /// A lane closed on some Mac, and when.
    public struct Closed: Codable, Equatable, Sendable {
        public var id: String
        public var at: Date

        public init(id: String, at: Date) {
            self.id = id
            self.at = at
        }
    }

    public static let currentVersion = 1
    /// How long a closed lane is remembered.
    public static let tombstoneLifetime: TimeInterval = 7 * 24 * 60 * 60

    public var version: Int
    public var lanes: [Lane]
    public var closed: [Closed]
    /// False when the list only mirrors rows between Macs: a tool that
    /// restarts sessions after a reboot (`agent-lanes-restore`) must leave
    /// every lane in it alone. Once any copy says false, the merge stays false.
    public var restore: Bool

    public init(lanes: [Lane] = [], closed: [Closed] = [], restore: Bool = true) {
        self.version = Self.currentVersion
        self.lanes = lanes
        self.closed = closed
        self.restore = restore
    }

    public func lane(_ id: String) -> Lane? { lanes.first { $0.id == id } }

    /// Now, to the second, as the file records times.
    public static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    // MARK: Merging

    /// Every copy merged: per lane the newest `updated` wins (a later copy
    /// on a tie), the newest close per id is kept, a lane closed at or after
    /// its `updated` is dropped, and closes older than a week, or older than
    /// the lane they name, are forgotten.
    public static func merge(_ copies: [SharedLaneList], now: Date = SharedLaneList.now(),
                             generated: Set<String> = []) -> SharedLaneList {
        var closedAt: [String: Date] = [:]
        var lanes: [String: Lane] = [:]
        var firstSeen: [String] = []
        let restore = copies.allSatisfy(\.restore)
        for copy in copies {
            for close in copy.closed {
                closedAt[close.id] = max(closedAt[close.id] ?? .distantPast, close.at)
            }
            for lane in copy.lanes {
                if let held = lanes[lane.id] {
                    if lane.updated >= held.updated { lanes[lane.id] = lane }
                } else {
                    lanes[lane.id] = lane
                    firstSeen.append(lane.id)
                }
            }
        }
        var live = firstSeen.compactMap { id -> Lane? in
            guard let lane = lanes[id] else { return nil }
            if let at = closedAt[id], at >= lane.updated { return nil }
            return lane
        }
        // Rows on one backend session are one lane: the oldest stays, and the
        // rest are closed so every other copy drops them too.
        let duplicates = duplicates(in: live, generated: generated)
        if !duplicates.isEmpty {
            for lane in live where duplicates[lane.id] != nil {
                closedAt[lane.id] = max(now, lane.updated)
            }
            live.removeAll { duplicates[$0.id] != nil }
        }
        let liveIDs = Set(live.map(\.id))
        let cutoff = now.addingTimeInterval(-tombstoneLifetime)
        var closed: [Closed] = []
        for (id, at) in closedAt where at > cutoff && !liveIDs.contains(id) {
            closed.append(Closed(id: id, at: at))
        }
        closed.sort { (a: Closed, b: Closed) -> Bool in a.at == b.at ? a.id < b.id : a.at < b.at }
        let indexed: [(offset: Int, element: Lane)] = Array(live.enumerated())
        let ordered: [Lane] = indexed.sorted { (a, b) -> Bool in
            if a.element.order != b.element.order { return a.element.order < b.element.order }
            return a.offset < b.offset
        }.map { $0.element }
        return SharedLaneList(lanes: ordered, closed: closed, restore: restore)
    }

    /// One sync's merge. `local` is this Mac's lanes as they stand, their
    /// `updated` ignored: a lane unchanged since `base` (the list as last
    /// synced) keeps base's time and anything else changed here now.
    ///
    /// A lane this Mac has never synced is merged, never dropped and never
    /// just overwritten. One `remote` lacks is added, stamped `edited` (when
    /// this Mac last changed its layout, else now). One `remote` has too is
    /// the union of both copies: the fields of the newer copy win, and it is
    /// pinned when either copy was. `closing` are the lanes closed here since
    /// the last sync, and `restores` is whether a tool may restart the list's
    /// lanes after a reboot.
    public static func reconcile(local: [Lane], base: SharedLaneList, remote: SharedLaneList,
                                 closing: [Closed], restores: Bool = true, edited: Date? = nil,
                                 now: Date = SharedLaneList.now(), generated: Set<String> = []) -> SharedLaneList {
        let moved = movedLanes(local: local, base: base)
        let reordered = !moved.isEmpty
        let stamped = local.map { lane -> Lane in
            var lane = lane
            if let known = base.lane(lane.id) {
                guard known.sameContent(as: lane) else {
                    lane.updated = now
                    return lane
                }
                // Unchanged here, so the hub's copy stands, even one changed
                // within the same second as the last sync. A lane moved in
                // the list here keeps the hub's content at its new place.
                if var theirs = remote.lane(lane.id) {
                    if reordered {
                        theirs.order = lane.order
                        if moved.contains(lane.id) { theirs.updated = now }
                    }
                    return theirs
                }
                lane.updated = moved.contains(lane.id) ? now : known.updated
            } else if let theirs = remote.lane(lane.id) {
                return firstMerge(mine: lane, theirs: theirs, edited: edited, now: now)
            } else {
                lane.updated = min(edited ?? now, now)
            }
            return lane
        }
        var merged = merge([remote, SharedLaneList(lanes: stamped, closed: closing, restore: restores)], now: now,
                           generated: generated)
        for index in merged.lanes.indices { merged.lanes[index].order = index }
        return merged
    }

    /// The lanes whose neighbour above is not the one `base` had, among the
    /// lanes both lists hold: a lane the person moved here, and the one it
    /// now sits above.
    static func movedLanes(local: [Lane], base: SharedLaneList) -> Set<String> {
        let held = Set(base.lanes.map(\.id)).intersection(local.map(\.id))
        let before = base.lanes.map(\.id).filter(held.contains)
        let now = local.map(\.id).filter(held.contains)
        guard before != now else { return [] }
        func above(_ id: String, in ids: [String]) -> String? {
            guard let index = ids.firstIndex(of: id), index > 0 else { return nil }
            return ids[index - 1]
        }
        return Set(now.filter { above($0, in: before) != above($0, in: now) })
    }

    /// The first time this Mac meets a lane another Mac already shared.
    static func firstMerge(mine: Lane, theirs: Lane, edited: Date?, now: Date) -> Lane {
        if mine.sameContent(as: theirs) { return theirs }
        var mine = mine
        mine.updated = min(edited ?? .distantPast, now)
        var winner = mine.updated > theirs.updated ? mine : theirs
        if mine.pinned == true || theirs.pinned == true { winner.pinned = true }
        if winner.sameContent(as: theirs) {
            winner.updated = theirs.updated
        } else if winner.sameContent(as: mine) {
            winner.updated = mine.updated
        } else {
            winner.updated = now
        }
        return winner
    }

    // MARK: Reading and writing

    public static func decode(_ data: Data) throws -> SharedLaneList {
        try JSONDecoder().decode(SharedLaneList.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    // MARK: Paths

    /// `/Users/x/a` → `~/a`, for paths under the home folder.
    public static func tildePath(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// `~/a` → `/Users/x/a`.
    public static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

// MARK: Coding

extension SharedLaneList: Codable {
    private enum CodingKeys: String, CodingKey { case version, lanes, closed, restore }

    /// One lane or close that does not decode is skipped, not the file.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        lanes = (try container.decodeIfPresent([Lenient<Lane>].self, forKey: .lanes) ?? []).compactMap(\.value)
        closed = (try container.decodeIfPresent([Lenient<Closed>].self, forKey: .closed) ?? []).compactMap(\.value)
        restore = try container.decodeIfPresent(Bool.self, forKey: .restore) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(lanes, forKey: .lanes)
        try container.encode(closed, forKey: .closed)
        try container.encode(restore, forKey: .restore)
    }
}

extension SharedLaneList.Closed {
    private enum CodingKeys: String, CodingKey { case id, at }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        at = try SharedLaneDate.decode(container.decode(String.self, forKey: .at))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(SharedLaneDate.encode(at), forKey: .at)
    }
}

extension SharedLaneList.Lane: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, directory, backendID, command, variantFlag, variant, host, section, pinned, order, updated
        case icon, tint, sessionName, agentSessionID, overlay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        backendID = try c.decode(String.self, forKey: .backendID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        variantFlag = try c.decodeIfPresent(String.self, forKey: .variantFlag)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        section = try c.decodeIfPresent(String.self, forKey: .section)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        tint = try c.decodeIfPresent(String.self, forKey: .tint)
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName)
        agentSessionID = try c.decodeIfPresent(String.self, forKey: .agentSessionID)
        overlay = try c.decodeIfPresent(Bool.self, forKey: .overlay)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        updated = try c.decodeIfPresent(String.self, forKey: .updated).map(SharedLaneDate.decode) ?? .distantPast
    }

    /// Every key is written, unset ones as null, so the file reads the same
    /// to a shell script whichever Mac wrote it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(directory, forKey: .directory)
        try c.encode(backendID, forKey: .backendID)
        try c.encode(command, forKey: .command)
        try c.encode(variantFlag, forKey: .variantFlag)
        try c.encode(variant, forKey: .variant)
        try c.encode(host, forKey: .host)
        try c.encode(section, forKey: .section)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(icon, forKey: .icon)
        try c.encode(tint, forKey: .tint)
        try c.encode(sessionName, forKey: .sessionName)
        try c.encode(agentSessionID, forKey: .agentSessionID)
        try c.encode(overlay, forKey: .overlay)
        try c.encode(order, forKey: .order)
        try c.encode(SharedLaneDate.encode(updated), forKey: .updated)
    }
}

/// ISO 8601 in UTC to the second (`2026-01-02T03:04:05Z`); fractional
/// seconds and offsets are read too.
enum SharedLaneDate {
    struct Invalid: Error {}

    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func decode(_ text: String) throws -> Date {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        }
        throw Invalid()
    }
}

// MARK: Transport

/// Where the shared lane list is read from and written to. Both calls block,
/// and are made off the main thread.
public protocol SharedLaneTransport: Sendable {
    /// The file's bytes, or nil when there is no file yet. Throws when the
    /// file cannot be reached, so the app falls back to its cache.
    func read() throws -> Data?
    /// Replace the file in one step, so a reader never sees half of it.
    func write(_ data: Data) throws
}

/// Where an app's shared lane list lives on the hub.
public enum SharedLanePaths {
    /// `.local/state/agentsmate/<app id>/lanes.json`, under the home folder.
    public static func relativePath(appID: String) -> String {
        ".local/state/agentsmate/\(appID)/lanes.json"
    }

    /// The claims on sessions every Mac shares (``SessionOwners/SharedFile``).
    public static let ownersRelativePath = ".local/state/agentsmate/session-owner-shared.json"

    /// Whether a path under the home folder can go in an ssh command unquoted.
    public static func isValidRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("..")
            && path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-/".contains($0)) }
    }

    /// Whether an app id can go in a path and an ssh command unquoted.
    public static func isValidAppID(_ appID: String) -> Bool {
        !appID.isEmpty && !appID.hasPrefix(".") && !appID.contains("..")
            && appID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}

/// The hub's own copy: read and written directly, the write to a temporary
/// file beside it and renamed over it.
public struct LocalSharedLaneTransport: SharedLaneTransport {
    public var file: URL
    /// Write the file readable by this user alone, in a folder that is too.
    public var isPrivate: Bool

    public init(file: URL, isPrivate: Bool = false) {
        self.file = file
        self.isPrivate = isPrivate
    }

    public init(appID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.file = home.appendingPathComponent(SharedLanePaths.relativePath(appID: appID))
        self.isPrivate = false
    }

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: isPrivate ? [.posixPermissions: 0o700] : nil)
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(file.lastPathComponent + ".tmp.\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: temp)
        if isPrivate { chmod(temp.path, 0o600) }
        guard rename(temp.path, file.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// Another Mac's copy: the hub's file over ssh, read with `cat` and written
/// to a temporary file there that is then renamed over it.
public struct SSHSharedLaneTransport: SharedLaneTransport {
    public struct Failed: Error, CustomStringConvertible {
        public var status: Int32
        public var message: String
        public var description: String { "ssh exited \(status): \(message)" }
    }

    public var hub: String
    public var appID: String
    public var ssh: String
    /// How long one ssh call may take in all.
    public var timeout: TimeInterval
    /// The file under the hub's home folder, when it is not the app's lane list.
    public var relativePath: String?
    /// Write the file readable by its user alone.
    public var isPrivate: Bool

    public init(hub: String, appID: String, ssh: String = "/usr/bin/ssh", timeout: TimeInterval = 20,
                relativePath: String? = nil, isPrivate: Bool = false) {
        self.hub = hub
        self.appID = appID
        self.ssh = ssh
        self.timeout = timeout
        self.relativePath = relativePath
        self.isPrivate = isPrivate
    }

    var path: String { "~/" + (relativePath ?? SharedLanePaths.relativePath(appID: appID)) }

    /// The command run on the hub to print the file, or nothing when there is none.
    var readCommand: String { "if [ -f \(path) ]; then cat \(path); fi" }

    /// The command run on the hub to replace the file from standard input.
    var writeCommand: String {
        let directory = (path as NSString).deletingLastPathComponent
        let mask = isPrivate ? "umask 077 && " : ""
        return "\(mask)mkdir -p \(directory) && cat > \(path).tmp.$$ && mv \(path).tmp.$$ \(path)"
    }

    func arguments(_ remote: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", hub, remote]
    }

    public func read() throws -> Data? {
        let out = try run(arguments(readCommand), input: nil)
        return out.isEmpty ? nil : out
    }

    public func write(_ data: Data) throws {
        _ = try run(arguments(writeCommand), input: data)
    }

    private func run(_ arguments: [String], input: Data?) throws -> Data {
        guard AgentHosts.isValidName(hub), SharedLanePaths.isValidAppID(appID),
              relativePath.map(SharedLanePaths.isValidRelativePath) ?? true else {
            throw Failed(status: -1, message: "not a usable hub or app id")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if let input {
            DispatchQueue.global(qos: .utility).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        // Read while it runs, so a large file never fills the pipe and stalls ssh.
        nonisolated(unsafe) var output = Data()
        nonisolated(unsafe) var errors = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            errors = stderr.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            throw Failed(status: -1, message: "timed out")
        }
        reading.wait()
        guard process.terminationStatus == 0 else {
            throw Failed(status: process.terminationStatus,
                         message: String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}

// MARK: Settings

/// Turns the shared lane list on for an app, when the hosts registry is there.
public struct SharedLaneSettings: Sendable {
    /// The app's bundle identifier; names its list on the hub.
    public var appID: String
    /// Where `hosts.conf` and `self` are.
    public var hostsDirectory: URL
    /// The list as last fetched, for when the hub cannot be reached.
    public var cacheFile: URL
    /// Whether a tool may restart the list's lanes after a reboot
    /// (``SharedLaneList/restore``). An app that only wants its rows
    /// mirrored between Macs passes false, and the list says so.
    public var restores: Bool
    /// Replaces the transport the registry picks, for tests.
    public var transport: (any SharedLaneTransport)?
    /// Replaces the registry read from ``hostsDirectory``, for tests.
    public var hosts: AgentHosts?
    /// Replaces where the Macs' claims on sessions are shared, for tests.
    public var ownerTransport: (any SharedLaneTransport)?

    public init(appID: String, hostsDirectory: URL = AgentHosts.defaultDirectory, cacheFile: URL? = nil,
                restores: Bool = true, transport: (any SharedLaneTransport)? = nil, hosts: AgentHosts? = nil,
                ownerTransport: (any SharedLaneTransport)? = nil) {
        self.ownerTransport = ownerTransport
        self.appID = appID
        self.hostsDirectory = hostsDirectory
        self.cacheFile = cacheFile ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appID, isDirectory: true).appendingPathComponent("shared-lanes.json")
        self.restores = restores
        self.transport = transport
        self.hosts = hosts
    }

    /// The default: on for an app bundle with an identifier, so a test
    /// runner or command-line tool never touches a real hub. Sharing still
    /// waits for the hosts registry; without it nothing changes.
    public static func automatic(bundle: Bundle = .main, restores: Bool = true) -> SharedLaneSettings? {
        guard bundle.bundleURL.pathExtension == "app", let id = bundle.bundleIdentifier,
              SharedLanePaths.isValidAppID(id) else { return nil }
        return SharedLaneSettings(appID: id, restores: restores)
    }

    /// This Mac's name, and how it reaches the claims on sessions that every
    /// Mac shares: directly on the hub, over ssh from anywhere else. Nil
    /// without a registry.
    func resolveOwners() -> (host: String, transport: any SharedLaneTransport)? {
        guard SharedLanePaths.isValidAppID(appID), let hosts = hosts ?? AgentHosts.load(from: hostsDirectory),
              let hub = hosts.hub, AgentHosts.isValidName(hosts.selfName) else { return nil }
        if let ownerTransport { return (hosts.selfName, ownerTransport) }
        if hosts.isHub {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(SharedLanePaths.ownersRelativePath)
            return (hosts.selfName, LocalSharedLaneTransport(file: file, isPrivate: true))
        }
        return (hosts.selfName, SSHSharedLaneTransport(hub: hub.name, appID: "session-owner",
                                                       relativePath: SharedLanePaths.ownersRelativePath, isPrivate: true))
    }

    /// The registry, and how this Mac reaches the hub's list: directly on
    /// the hub, over ssh from anywhere else. Nil without a registry.
    func resolve() -> (hosts: AgentHosts, transport: any SharedLaneTransport)? {
        guard SharedLanePaths.isValidAppID(appID), let hosts = hosts ?? AgentHosts.load(from: hostsDirectory),
              let hub = hosts.hub else { return nil }
        if let transport { return (hosts, transport) }
        if hosts.isHub { return (hosts, LocalSharedLaneTransport(appID: appID)) }
        return (hosts, SSHSharedLaneTransport(hub: hub.name, appID: appID))
    }
}
