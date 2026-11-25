import Foundation

/// Which app the person last worked in for each session, so that when several
/// apps list the same session only one of them notifies about it.
///
/// The file is `<state home>/agentsmate/session-owner.json`
/// (``standardURL(environment:)``), one per user. It maps a session key
/// (the agent's session id, else the tmux session name, else the lane's
/// folder) to the app that last claimed it:
///
/// ```json
/// {"c0ffee00": {"app": "com.example.app", "at": "2026-11-25T18:00:00Z", "created_by": "com.example.app"}}
/// ```
///
/// `created_by` is optional: the app that made the session, kept as the
/// fallback owner for as long as the entry lives. Writes take a lock on a file
/// beside it, go to a temporary file and are renamed into place, so a reader
/// sees the old file or the new one; the file is mode 600 and its folder 700.
/// A reader treats a file that is missing, unreadable, bigger than
/// ``maximumFileSize``, not owned by the user, or writable by group or others,
/// as empty, and skips an entry it cannot read.
public enum SessionOwners {
    public struct Entry: Equatable, Sendable {
        public var app: String
        public var at: Date
        public var createdBy: String?

        public init(app: String, at: Date, createdBy: String? = nil) {
            self.app = app
            self.at = at
            self.createdBy = createdBy
        }
    }

    /// What a session is known by: its agent session ids and tmux name, or, when it has neither, its folder.
    public struct Keys: Equatable, Sendable {
        public var all: [String]

        public init(sessionIDs: [String?] = [], tmuxName: String? = nil, folder: String? = nil) {
            var keys: [String] = []
            for value in sessionIDs + [tmuxName] {
                if let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, !keys.contains(value) { keys.append(value) }
            }
            if keys.isEmpty, let folder = folder?.trimmingCharacters(in: .whitespaces), !folder.isEmpty { keys = [folder] }
            all = keys
        }

        public var isEmpty: Bool { all.isEmpty }
    }

    public struct Snapshot: Equatable, Sendable {
        public var entries: [String: Entry]

        public init(entries: [String: Entry] = [:]) { self.entries = entries }

        /// The freshest claim among `keys` that is not older than ``ownerMaxAge``
        /// (nor further ahead of `now` than ``clockSkew``).
        public func owner(for keys: Keys, now: Date = Date()) -> Entry? {
            keys.all.compactMap { entries[$0] }
                .filter { now.timeIntervalSince($0.at) <= SessionOwners.ownerMaxAge && $0.at.timeIntervalSince(now) <= SessionOwners.clockSkew }
                .max { ($0.at, $0.app) < ($1.at, $1.app) }
        }

        /// The app that made the session, when an entry says.
        public func creator(for keys: Keys) -> String? {
            keys.all.compactMap { entries[$0] }.sorted { ($0.at, $0.app) > ($1.at, $1.app) }.compactMap(\.createdBy).first
        }
    }

    public static let maximumFileSize = 1 << 20
    /// How long a claim counts. Older, the file says nothing about who owns the session now.
    public static let ownerMaxAge: TimeInterval = 30 * 24 * 3600
    /// How long an entry is kept at all, for the creator it records.
    public static let entryMaxAge: TimeInterval = 180 * 24 * 3600
    public static let clockSkew: TimeInterval = 5 * 60
    /// The most entries kept; the oldest go first.
    public static let maximumEntries = 5000

    /// `<state home>/agentsmate/session-owner.json`.
    public static func standardURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        DisplayedExport.agentsMateStateDirectory(environment: environment)
            .appendingPathComponent("session-owner.json", isDirectory: false)
    }

    // MARK: Reading

    /// The file at `url`, or an empty snapshot when it cannot be trusted
    /// (see the type's description).
    public static func load(_ url: URL, now: Date = Date()) -> Snapshot {
        guard let data = readPrivate(url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Snapshot()
        }
        var entries: [String: Entry] = [:]
        for (key, value) in object {
            guard !key.isEmpty, let fields = value as? [String: Any], let app = fields["app"] as? String, !app.isEmpty,
                  let text = fields["at"] as? String, let at = parseDate(text),
                  now.timeIntervalSince(at) <= entryMaxAge else { continue }
            let creator = (fields["created_by"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            entries[key] = Entry(app: app, at: at, createdBy: creator)
        }
        return Snapshot(entries: entries)
    }

    /// The bytes of a regular file that the user owns and nobody else can write, within the size limit.
    static func readPrivate(_ url: URL) -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= maximumFileSize else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: Writing

    /// Record `app` as the owner of the session `keys` name, as of `at`. With
    /// `created`, `app` is also recorded as the session's creator unless an
    /// entry already names one. Returns whether the file was written.
    @discardableResult
    public static func claim(_ keys: Keys, app: String, created: Bool = false, at: Date = Date(), in url: URL) -> Bool {
        guard !keys.isEmpty, !app.isEmpty else { return false }
        return update(url, now: at) { entries in
            let creator = keys.all.compactMap { entries[$0]?.createdBy }.first ?? (created ? app : nil)
            for key in keys.all { entries[key] = Entry(app: app, at: at, createdBy: entries[key]?.createdBy ?? creator) }
        }
    }

    /// Forget the session `keys` name.
    @discardableResult
    public static func release(_ keys: Keys, in url: URL, now: Date = Date()) -> Bool {
        update(url, now: now) { entries in for key in keys.all { entries.removeValue(forKey: key) } }
    }

    private static func update(_ url: URL, now: Date, _ change: (inout [String: Entry]) -> Void) -> Bool {
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        else { return false }
        let lock = open(url.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        var locked = false
        for _ in 0..<100 where !locked {
            if flock(lock, LOCK_EX | LOCK_NB) == 0 { locked = true } else { usleep(20_000) }
        }
        guard locked else { return false }
        defer { flock(lock, LOCK_UN) }
        var entries = load(url, now: now).entries
        change(&entries)
        if entries.count > maximumEntries {
            for key in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - maximumEntries).map(\.key) {
                entries.removeValue(forKey: key)
            }
        }
        var object: [String: Any] = [:]
        for (key, entry) in entries {
            var fields: [String: Any] = ["app": entry.app, "at": formatter.string(from: entry.at)]
            if let creator = entry.createdBy { fields["created_by"] = creator }
            object[key] = fields
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? DisplayedExport.write(data, to: url)) != nil
    }

    // MARK: Deciding

    public enum Reason: String, Equatable, Sendable {
        /// The lane is not shared, so this app is the only one that lists it.
        case unshared
        /// An app claimed it by working in it.
        case recorded
        /// Nobody has worked in it since the claims aged out; the app that made it.
        case creator
        /// Nothing recorded: the lowest bundle id among the apps listing it.
        case tieBreak
    }

    public struct Decision: Equatable, Sendable {
        public var owner: String
        public var reason: Reason
    }

    /// The app that should notify about the session `keys` name: this app
    /// (`me`) for an unshared lane; else the app that last worked in it; else
    /// the app that created it; else the lowest bundle id among `peers` (the
    /// other apps that list the session) and `me`.
    ///
    /// An app that is not running (`isRunning` says no; this app always is)
    /// cannot notify, so it is passed over at each step and the next applies:
    /// an alert that needs the person is never left to a closed app.
    public static func decide(keys: Keys, me: String, isShared: Bool, snapshot: Snapshot,
                              peers: () -> Set<String>, isRunning: (String) -> Bool = { _ in true },
                              now: Date = Date()) -> Decision {
        if !isShared { return Decision(owner: me, reason: .unshared) }
        let running = { (app: String) in app == me || isRunning(app) }
        if let entry = snapshot.owner(for: keys, now: now), running(entry.app) { return Decision(owner: entry.app, reason: .recorded) }
        if let creator = snapshot.creator(for: keys), running(creator) { return Decision(owner: creator, reason: .creator) }
        return Decision(owner: (peers().filter(running).union([me])).min() ?? me, reason: .tieBreak)
    }

    // MARK: Other apps listing a session

    /// How old another app's `displayed.json` may be and still say what it lists.
    public static let peerMaxAge: TimeInterval = 7 * 24 * 3600

    /// For each session key, the bundle ids of the other apps whose
    /// `displayed.json` lists it, from `<state home>/agentsmate/<bundle id>/`.
    /// A file that is not private, or old, is skipped.
    public static func peerIndex(excluding me: String, now: Date = Date(),
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: Set<String>] {
        let root = DisplayedExport.agentsMateStateDirectory(environment: environment)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var index: [String: Set<String>] = [:]
        for name in names where !name.hasPrefix(".") {
            let file = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("displayed.json")
            guard let data = readPrivate(file), let export = try? DisplayedExport.decoder.decode(DisplayedExport.self, from: data),
                  export.schemaVersion == DisplayedExport.schemaVersion, export.app.bundleID != me,
                  now.timeIntervalSince(export.writtenAt ?? .distantPast) <= peerMaxAge else { continue }
            for row in export.rows + export.allAgents {
                for key in [row.sessionID, row.attachedSessionID, row.sessionName, row.folder] {
                    if let key, !key.isEmpty { index[key, default: []].insert(export.app.bundleID) }
                }
            }
        }
        return index
    }

    // MARK: Watching

    /// Calls `onChange` (on `queue`) when something in the file's folder
    /// changes: a rename into place changes the folder, not the old file.
    public final class Watcher: @unchecked Sendable {
        private let source: DispatchSourceFileSystemObject?

        public init?(file url: URL, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler(handler: onChange)
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }

        deinit { source?.cancel() }
    }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ text: String) -> Date? {
        formatter.date(from: text) ?? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: text)
        }()
    }
}
