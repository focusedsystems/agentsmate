import AppKit
import AgentsMate
import AgentsMateStatus

/// Reads every Mac's snapshot and keeps the cards up to date: this Mac
/// every few seconds, the others over ssh less often. A Mac that does not
/// answer keeps its last cards and is marked unreachable.
@MainActor
final class BoardModel: ObservableObject {
    enum HostState: Equatable {
        case asking, answered(Date), unreachable
    }

    @Published private(set) var cards: [AgentBoard.Card] = []
    @Published private(set) var hostStates: [String: HostState] = [:]
    @Published var stopMessage: String?

    let localHost: String
    let remoteHosts: [String]
    private var snapshots: [String: AgentBoard.HostSnapshot] = [:]
    private var localTimer: Timer?
    private var remoteTimer: Timer?
    private var inFlight: Set<String> = []

    init() {
        let registry = AgentHosts.load()
        localHost = registry?.selfName ?? Host.current().localizedName ?? "this Mac"
        remoteHosts = (registry?.hosts ?? [])
            .filter { $0.platform == "mac" && $0.name.caseInsensitiveCompare(registry?.selfName ?? "") != .orderedSame }
            .map(\.name)
        for host in [localHost] + remoteHosts { hostStates[host] = .asking }
    }

    func start() {
        guard localTimer == nil else { return }
        refresh(remote: true)
        localTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(remote: false) }
        }
        remoteTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRemote() }
        }
    }

    func refresh(remote: Bool) {
        read(host: localHost, remote: false)
        if remote { refreshRemote() }
    }

    private func refreshRemote() {
        for host in remoteHosts { read(host: host, remote: true) }
    }

    private func read(host: String, remote: Bool) {
        guard inFlight.insert(host).inserted else { return }
        let marks = AgentBoard.Marks()
        let script = AgentBoard.script(marks: marks)
        Task.detached(priority: .utility) {
            let output = Self.run(script: script, host: remote ? host : nil)
            let snapshot = output.flatMap { AgentBoard.parse($0, host: host, marks: marks) }
            await MainActor.run { self.received(snapshot, host: host) }
        }
    }

    private func received(_ snapshot: AgentBoard.HostSnapshot?, host: String) {
        inFlight.remove(host)
        if var snapshot {
            // This Mac knows which apps run more surely than ps does.
            if host == localHost {
                let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                snapshot.runningApps = running
            }
            snapshots[host] = snapshot
            // Publish an answer only when it is news: a Mac that has answered
            // keeps its badge, and its tooltip time moves on every half minute.
            if case .answered(let at) = hostStates[host], Date().timeIntervalSince(at) < 30 {} else {
                hostStates[host] = .answered(Date())
            }
        } else if hostStates[host] != .unreachable {
            hostStates[host] = .unreachable
        }
        let next = AgentBoard.cards(from: Array(snapshots.values), localHost: localHost)
        if next != cards { cards = next }
    }

    nonisolated static func run(script: String, host: String?) -> String? {
        let process = Process()
        if let host {
            guard AgentSessionStop.isValidHost(host) else { return nil }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T", "--", host,
                                 "/bin/sh -c " + ShellWords.quote(script)]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if process.isRunning { process.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Actions

    func isLocal(_ host: String) -> Bool { host.caseInsensitiveCompare(localHost) == .orderedSame }

    /// Open the card's lane in its app on this Mac; a session no app lists
    /// opens in Terminal instead.
    func open(_ card: AgentBoard.Card) {
        guard let app = card.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else {
            if attachCommand(card) != nil { openInTerminal(card) } else { NSSound.beep() }
            return
        }
        request(.show, for: card, app: app)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The shell line that attaches the card's session, on its own Mac.
    func attachCommand(_ card: AgentBoard.Card) -> String? {
        let attach: String
        if card.backend == "claude-bg", let id = card.sessionID, AgentSessionStop.isValidClaudeID(id) {
            attach = "claude attach " + ShellWords.quote(id)
        } else if card.backend == "tmux", let name = card.sessionName, AgentSessionStop.isValidTmuxName(name) {
            attach = "tmux attach-session -t " + ShellWords.quote("=" + name)
        } else {
            return nil
        }
        if isLocal(card.host) { return "exec /bin/zsh -lc " + ShellWords.quote("exec " + attach) }
        guard AgentSessionStop.isValidHost(card.host) else { return nil }
        let remote = "/bin/zsh -lc " + ShellWords.quote("exec " + attach)
        return "exec /usr/bin/ssh -t -- " + ShellWords.quote(card.host) + " " + ShellWords.quote(remote)
    }

    /// Attach the session in a new Terminal window.
    func openInTerminal(_ card: AgentBoard.Card) {
        guard let line = attachCommand(card) else { NSSound.beep(); return }
        runInTerminal(line, title: card.title)
    }

    /// Run `line` in a new Terminal window, through a one-off `.command` file
    /// that removes itself.
    func runInTerminal(_ line: String, title: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsmate-attach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent(UUID().uuidString + ".command")
        let script = "#!/bin/zsh\nrm -f " + ShellWords.quote(file.path) + "\nprintf '\\e]0;%s\\a' "
            + ShellWords.quote(title) + "\n" + line + "\n"
        guard FileManager.default.createFile(atPath: file.path, contents: Data(script.utf8),
                                             attributes: [.posixPermissions: 0o700]) else { NSSound.beep(); return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func canClose(_ card: AgentBoard.Card) -> Bool {
        guard let app = card.app, card.laneID != nil else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty == false
    }

    /// Close the lane's row and terminal in its app; the session keeps running.
    func close(_ card: AgentBoard.Card) {
        guard canClose(card), let app = card.app else { return }
        request(.close, for: card, app: app)
    }

    private func request(_ action: LaneRequest.Action, for card: AgentBoard.Card, app: String) {
        LaneRequest(action: action, app: app, laneID: card.laneID, sessionID: card.sessionID,
                    conversationID: card.conversationID, sessionName: card.sessionName, host: card.host).send()
    }

    func stopTarget(_ card: AgentBoard.Card) -> AgentSessionStop.Target? {
        guard card.isRunning else { return nil }
        if card.backend == "claude-bg", let id = card.sessionID, AgentSessionStop.isValidClaudeID(id) {
            return .claudeBackground(id: id)
        }
        if card.backend == "tmux", let name = card.sessionName, AgentSessionStop.isValidTmuxName(name) {
            return .tmux(name: name)
        }
        return nil
    }

    /// End the session on the Mac it runs on. The caller has confirmed.
    func stop(_ card: AgentBoard.Card) {
        guard let target = stopTarget(card) else { return }
        let host = isLocal(card.host) ? nil : card.host
        let title = card.title
        Task {
            let outcome = await AgentSessionStop.run(target, host: host)
            if !outcome.stopped { stopMessage = "“\(title)” did not stop. " + (outcome.message ?? "") }
            refresh(remote: true)
        }
    }

    func revealFolder(_ card: AgentBoard.Card) {
        guard isLocal(card.host), let folder = card.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }
}

/// An app's name and icon on this Mac, by bundle id.
@MainActor
enum AppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(_ bundleID: String?) -> String {
        guard let bundleID else { return "No app" }
        if let name = names[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
        names[bundleID] = name
        return name
    }

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}
