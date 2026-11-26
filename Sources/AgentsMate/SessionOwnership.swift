import AppKit
import Foundation
import AgentsMateStatus

extension AgentLaneStore.Configuration {
    /// `<state home>/agentsmate/session-owner.json` for a running app bundle
    /// (``SessionOwners/standardURL(environment:)``); nil outside one, so a
    /// test host or a command-line tool records and gates nothing.
    public static var defaultSessionOwnerFile: URL? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return SessionOwners.standardURL()
    }
}

/// Which app the person last worked in for each session, as this app sees it.
/// Apps built on AgentsMate that list the same session share
/// ``SessionOwners``' file; only the app it names notifies, badges the Dock
/// or plays a sound for the session. The others show it, silently.
@MainActor
final class SessionOwnership {
    private weak var store: AgentLaneStore?
    let file: URL
    let appID: String
    private let isShared: (@Sendable (AgentLane) -> Bool)?
    private(set) var snapshot: SessionOwners.Snapshot
    private var watcher: SessionOwners.Watcher?
    private var backstop: CadenceTimer?
    private var peers: (index: [String: Set<String>], at: Date)?
    private let queue = DispatchQueue(label: "agentsmate.session-owner", qos: .utility)
    /// A claim within this long of the last one by the same app is not written again.
    static let refresh: TimeInterval = 30
    /// How long what other apps list is kept before it is read again.
    static let peerLifetime: TimeInterval = 30
    /// How often the file is read again whether or not a change was seen.
    static let backstopInterval: TimeInterval = 60
    /// Called on the main actor after the file changed.
    var onChange: (() -> Void)?
    /// Whether an app with this bundle id is running. Replaced in tests.
    var isRunning: (String) -> Bool = { id in
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    init(store: AgentLaneStore, file: URL, appID: String, isShared: (@Sendable (AgentLane) -> Bool)?, watches: Bool = true) {
        self.store = store
        self.file = file
        self.appID = appID
        self.isShared = isShared
        snapshot = SessionOwners.load(file)
        guard watches else { return }
        watcher = SessionOwners.Watcher(file: file, queue: queue) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reload() } }
        }
        backstop = CadenceTimer(interval: Self.backstopInterval) { [weak self] in self?.reload() }
    }

    func keys(for session: AgentLaneSession) -> SessionOwners.Keys {
        let lane = session.lane
        let running = session.record.flatMap { $0.state == .ended ? nil : $0 }
        return SessionOwners.Keys(sessionIDs: [lane.agentSessionID, running?.agentID, running?.sessionID],
                                  tmuxName: lane.sessionName ?? session.backend.sessionName(for: lane),
                                  folder: lane.directory?.path)
    }

    /// Who should notify about `session`. `fresh` reads the file now, for the
    /// moment before a notification, rather than trusting what was last read.
    func decision(for session: AgentLaneSession, fresh: Bool = false, now: Date = Date()) -> SessionOwners.Decision {
        if fresh { snapshot = SessionOwners.load(file, now: now) }
        let keys = keys(for: session)
        if store?.isDetached(session.id) == true { return unlistedDecision(keys: keys, now: now) }
        let shared = isShared?(session.lane) ?? false
        return SessionOwners.decide(keys: keys, me: appID, isShared: shared, snapshot: snapshot,
                                    peers: { self.peerApps(for: keys, now: now) },
                                    isRunning: isRunning, now: now)
    }

    /// Who owns a session this app only found running and does not list as a
    /// row of its own: never this app. Its own claims on it (made before it
    /// stopped listing it) are ignored, and the session goes to the app that
    /// last worked in it, made it, or lists it. Only when no other app does is
    /// it left to this one, so something still answers for it.
    private func unlistedDecision(keys: SessionOwners.Keys, now: Date) -> SessionOwners.Decision {
        var others = snapshot
        others.entries = others.entries.filter { $0.value.app != appID }
        func running(_ app: String) -> Bool { isRunning(app) }
        if let entry = others.owner(for: keys, now: now), running(entry.app) {
            return .init(owner: entry.app, reason: .recorded)
        }
        if let creator = others.creator(for: keys), creator != appID, running(creator) {
            return .init(owner: creator, reason: .creator)
        }
        if let peer = peerApps(for: keys, now: now).filter(running).min() { return .init(owner: peer, reason: .tieBreak) }
        return .init(owner: appID, reason: .unshared)
    }

    func owns(_ session: AgentLaneSession, fresh: Bool = false) -> Bool {
        decision(for: session, fresh: fresh).owner == appID
    }

    private func peerApps(for keys: SessionOwners.Keys, now: Date) -> Set<String> {
        if peers == nil || now.timeIntervalSince(peers!.at) > Self.peerLifetime {
            peers = (SessionOwners.peerIndex(excluding: appID, now: now), now)
        }
        return keys.all.reduce(into: Set<String>()) { $0.formUnion(peers?.index[$1] ?? []) }
    }

    /// The person is working in `session` here: this app becomes its owner.
    func claim(_ session: AgentLaneSession, created: Bool = false, now: Date = Date()) {
        let keys = keys(for: session)
        guard !keys.isEmpty, store?.isDetached(session.id) != true else { return }
        if !created, let entry = snapshot.owner(for: keys, now: now), entry.app == appID,
           now.timeIntervalSince(entry.at) < Self.refresh { return }
        let creator = keys.all.compactMap { snapshot.entries[$0]?.createdBy }.first ?? (created ? appID : nil)
        for key in keys.all { snapshot.entries[key] = .init(app: appID, at: now, createdBy: snapshot.entries[key]?.createdBy ?? creator) }
        let file = file, appID = appID
        queue.async { SessionOwners.claim(keys, app: appID, created: created, at: now, in: file) }
    }

    /// Wait for claims being written; for tests.
    func flush() { queue.sync {} }

    func reload() {
        let file = file
        queue.async { [weak self] in
            let loaded = SessionOwners.load(file)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.snapshot != loaded else { return }
                    self.snapshot = loaded
                    self.changed()
                }
            }
        }
    }

    private func changed() {
        // A session this app no longer speaks for: take back what it said.
        if let store {
            for session in store.sessions.values where session.needsAttention && !owns(session) { store.noteOwnershipLost(session.id) }
        }
        onChange?()
    }
}

extension AgentLaneStore {
    func startSessionOwnership() {
        ownership = nil
        guard let file = configuration.sessionOwnerFile,
              let appID = configuration.ownerAppID ?? Bundle.main.bundleIdentifier, !appID.isEmpty else { return }
        let ownership = SessionOwnership(store: self, file: file, appID: appID, isShared: configuration.isLaneShared)
        ownership.onChange = { [weak self] in
            self?.updateBadge()
            self?.displayedExporter?.changed()
        }
        self.ownership = ownership
    }

    /// Whether this app is the one to notify, badge and sound for `session`:
    /// always without the gate, for a lane that is not shared, or when the
    /// person last worked in it here.
    func ownsSession(_ session: AgentLaneSession) -> Bool {
        ownership?.owns(session) ?? true
    }

    /// The same, reading the file now: asked just before a notification, so a
    /// handoff the file has not yet been watched for still counts.
    func shouldNotify(for session: AgentLaneSession) -> Bool {
        ownership?.owns(session, fresh: true) ?? true
    }

    /// The app that notifies about `session`, for the displayed export.
    func ownerApp(of session: AgentLaneSession) -> String? {
        if let ownership { return ownership.decision(for: session).owner }
        return configuration.ownerAppID ?? Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The person is working in `session` in this app.
    func claimOwnership(of session: AgentLaneSession, created: Bool = false) {
        guard let ownership else { return }
        ownership.claim(session, created: created)
        updateBadge()
        displayedExporter?.changed()
    }

    /// Another app took over a session this app owned: its delivered
    /// notification goes, and nothing more is said for it here.
    func noteOwnershipLost(_ id: AgentLane.ID) {
        notifier?.clear(id)
    }
}
