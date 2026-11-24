import AppKit
import Combine
import SwiftTerm
import AgentsMateStatus

/// What a lane row shows: the agent's own report when its hooks have one,
/// otherwise whether the terminal here is attached.
public enum LaneDisplayStatus: Equatable, Sendable {
    case notOpened, attached, running, waitingForInput, permissionRequested, done, idle, detached

    public var title: String {
        switch self {
        case .notOpened: "Not attached"
        case .attached: "Attached"
        case .running: "Running"
        case .waitingForInput: "Waiting for you"
        case .permissionRequested: "Asking permission"
        case .done: "Done"
        case .idle: "Idle"
        case .detached: "Detached"
        }
    }
}

/// The terminal for one lane: a pseudo-terminal running the backend's
/// process, and the view that draws it. The view lives as long as the
/// session, so switching rows or hiding the lanes never ends it.
@MainActor
public final class AgentLaneSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    public private(set) var lane: AgentLane
    public private(set) var backend: any LaneBackend
    public nonisolated let id: String

    /// Replaced on reattach, so a fresh process gets a fresh screen.
    @Published public private(set) var view: AgentTerminalView
    @Published public private(set) var isStarted = false {
        didSet { if isStarted != oldValue { onAttachmentChange?(self) } }
    }
    @Published public private(set) var hasExited = false {
        didSet { if hasExited != oldValue { onAttachmentChange?(self) } }
    }
    /// What the program calls itself: Claude's session name, or the shell's title.
    @Published public private(set) var programTitle: String?
    /// The shell's working directory, followed as it changes.
    @Published public private(set) var currentDirectory: String {
        didSet { if currentDirectory != oldValue { onDirectoryChange?(self) } }
    }
    /// The latest record from the status feed for this lane.
    @Published public private(set) var record: LaneStatus?
    /// Set when a record that wants a person arrives while the lane is out of sight.
    @Published public private(set) var needsAttention = false {
        didSet { if needsAttention != oldValue { onAttentionChange?(self) } }
    }
    /// Called whenever the unread mark is set or cleared, so the Dock badge
    /// follows the mark however it changed.
    var onAttentionChange: ((AgentLaneSession) -> Void)?
    /// When the terminal last printed, for the recency sorts. Not a status:
    /// the status comes from the agent's own reports.
    @Published public private(set) var lastOutputAt: Date?

    /// The latest of the last output here and the last status report, or
    /// what the live snapshot said while there is neither.
    public var lastActivity: Date? {
        switch (lastOutputAt, record?.updatedAt) {
        case let (output?, report?): max(output, report)
        case let (output, report): output ?? report ?? liveHint?.lastActivity
        }
    }

    /// What the live snapshot said about this lane's session, until the
    /// status feed, presence or the lane's host says. Nil once they have.
    @Published public internal(set) var liveHint: LiveSessionHint?

    /// The hint, while nothing more current is known about the lane.
    var standingHint: LiveSessionHint? {
        guard let liveHint, !isStarted, !isPresent, record == nil || record?.state == .ended else { return nil }
        return liveHint
    }

    /// One line on what the agent is working on, when summaries are on.
    @Published public internal(set) var summary: String?
    /// The person's last few prompts in this lane, from its conversation file.
    @Published public internal(set) var recentPrompts: [String] = []
    /// The agent's last reply, from its conversation file.
    @Published public internal(set) var lastReply: String?
    /// Pull request links the agent posted in its replies, oldest first.
    @Published public internal(set) var pullRequestLinks: [URL] = []
    /// Every pull request the agent has posted in this lane, oldest first,
    /// with its state once a resolver has looked it up. Kept across
    /// conversations and relaunches.
    @Published public internal(set) var pullRequests: [LanePullRequest] = []
    /// Background shells the agent started that have not finished.
    @Published public internal(set) var openBackgroundTasks: [LaneTranscript.BackgroundTask] = []
    /// What a script in the lane last said about its work.
    @Published public internal(set) var note: LaneNote?
    /// Branch, pull request and ports, when the store reads them.
    @Published public internal(set) var rowMetadata = LaneRowMetadata()

    /// The pull requests the row, its hover and its menu show: the agent's,
    /// then the one for the folder's branch when the agent has not posted it.
    public var displayedPullRequests: [LanePullRequest] {
        let branch = rowMetadata.pullRequest.flatMap { pr in
            pr.url.map { LanePullRequest(url: $0, details: .init(number: pr.number, state: pr.state,
                                                                 repository: PullRequestKey.repository(of: $0)),
                                         source: .branch) }
        }
        return PullRequestKey.merge(agent: pullRequests, branch: branch)
    }

    /// The icon and colour the person chose, which win over the lane's own.
    @Published public internal(set) var customIcon: LaneIcon?
    @Published public internal(set) var customTintHex: String?

    /// The icon to draw: the person's choice, else the app's.
    public var icon: LaneIcon { customIcon ?? lane.resolvedIcon }
    /// The colour to draw as `#RRGGBB`; nil is the accent colour.
    public var tintHex: String? { customTintHex ?? lane.tintHex }

    /// The shell's process id, while attached.
    public var shellPID: pid_t? {
        guard isAttached, let pid = view.process?.shellPid, pid > 0 else { return nil }
        return pid
    }

    /// The lane's session runs with no terminal attached anywhere.
    @Published public private(set) var isOrphan = false
    /// A presence source lists the lane's session as running.
    @Published public private(set) var isPresent = false
    /// The presence source found the session by its tmux name, so it is
    /// this lane's own and not just a session in the same folder.
    public private(set) var isPresentByName = false
    /// The tmux name the presence source found the session under, when it
    /// matched by name. Launch attaches exactly this session.
    public private(set) var presenceName: String?

    /// The lane's session is running somewhere: a presence source or a
    /// daemon's session list has it, whether or not it is attached here.
    public var isAlive: Bool {
        isPresent || (record.map { $0.isPolled && $0.state != .ended } ?? false) || standingHint?.isAlive == true
    }

    /// Attached here, or running somewhere: what the Active filter shows.
    public var isActive: Bool { isAttached || isAlive }
    /// Bumped on every start, so SwiftUI re-hosts the new view.
    @Published public private(set) var generation = 0
    @Published public var wantsFocus = false

    var onShortcut: ((TerminalShortcut) -> Bool)?
    var shortcutResolver: ((NSEvent) -> TerminalShortcut?)?
    var onOpenLink: ((URL) -> Bool)?
    private var poll: CadenceTimer?

    /// Whether the row is on screen.
    var isShown = false {
        didSet {
            if isShown { needsAttention = false }
            if isShown != oldValue { visibilityChanged() }
        }
    }
    /// Whether the row is the selected one, on screen or not.
    var isSelected = false {
        didSet { if isSelected != oldValue { visibilityChanged() } }
    }
    /// The shell reports its directory itself (OSC 7), so the kernel need
    /// not be asked.
    private(set) var directoryFromShell = false
    /// Called when the working directory changes, however it was learned.
    var onDirectoryChange: ((AgentLaneSession) -> Void)?
    /// Called when the lane's terminal starts or ends.
    var onAttachmentChange: ((AgentLaneSession) -> Void)?

    init(lane: AgentLane, backend: any LaneBackend) {
        self.lane = lane
        self.backend = backend
        self.id = lane.id
        self.currentDirectory = lane.path
        self.view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
    }

    public var isAttached: Bool { isStarted && !hasExited }

    /// Start by resuming the agent's last conversation, once. Set for lanes
    /// brought back at launch.
    public var resumeOnStart = false
    /// What the next start runs in place of the backend's launch: one that
    /// only attaches a running session. If it fails, the terminal ends and
    /// the row shows Reattach, and nothing else runs.
    var attachOnlyLaunch: TerminalLaunch?

    /// The person's login shell, which runs every lane's command.
    nonisolated static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    /// Whether a program other than the shell has the terminal: the
    /// foreground process group of the pseudo-terminal is not the shell's.
    public var programIsForeground: Bool {
        guard isAttached, let process = view.process, process.childfd >= 0 else { return false }
        let group = tcgetpgrp(process.childfd)
        return group > 0 && group != process.shellPid
    }

    /// Type `text` into the lane's program as a paste. With `submit`, Return
    /// follows. Returns false, typing nothing, when no program is in the
    /// foreground or it does not take bracketed paste, so text never lands
    /// at a bare shell prompt.
    @discardableResult
    public func send(_ text: String, submit: Bool = false) -> Bool {
        guard programIsForeground, view.acceptsBracketedPaste else { return false }
        view.pasteText(text)
        if submit { view.send(txt: "\r") }
        return true
    }

    /// Read the agent's input line off the screen, under the cursor. A
    /// screen scrolled back into its history reads as unknown, since the
    /// cursor's row is then not the one on show.
    func readInputLine() -> AgentPromptLine.Reading {
        guard isAttached else { return .unknown }
        if view.canScroll, view.scrollPosition < 1 { return .unknown }
        return AgentPromptLine.read(view.getTerminal())
    }

    /// A short line the row shows for a while after a rename that did not
    /// reach the agent, saying why.
    @Published public internal(set) var renameNotice: String?
    private var renameNoticeClear: DispatchWorkItem?

    func showRenameNotice(_ text: String?, for seconds: TimeInterval = 8) {
        renameNoticeClear?.cancel()
        renameNotice = text
        guard text != nil else { return }
        let clear = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.renameNotice = nil }
        }
        renameNoticeClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: clear)
    }

    /// Type `command` into the agent, then Return in a write of its own a
    /// moment later, since a remote pane drops a Return sent with the text.
    func typeCommand(_ command: String) {
        let target = ObjectIdentifier(view)
        view.send(txt: command)
        DispatchQueue.main.asyncAfter(deadline: .now() + LaneRename.returnDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isAttached, ObjectIdentifier(self.view) == target else { return }
                self.view.send(txt: "\r")
            }
        }
    }

    /// Clear the row's unread mark without showing it.
    func markRead() {
        if needsAttention { needsAttention = false }
    }

    /// Whether text typed in now reaches a program that takes a paste.
    var acceptsText: Bool { programIsForeground && view.acceptsBracketedPaste }

    public var status: LaneDisplayStatus {
        if let record, record.state != .ended {
            switch record.state {
            case .running: return .running
            case .waitingForInput: return .waitingForInput
            case .permissionRequested: return .permissionRequested
            case .done: return record.isPolled ? .idle : .done
            case .ended: break
            }
        }
        if let hint = standingHint { return hint.displayStatus }
        if !isStarted { return .notOpened }
        return hasExited ? .detached : .attached
    }

    /// The row's title: the app's name for the lane, or for a lane the
    /// person opened, what the program running in it calls itself.
    public var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        guard lane.isClosable else { return lane.title }
        if let title = metadata?.title { return title }
        if let task = programTitle.flatMap(TerminalTitle.task(from:)) { return task }
        return lane.title
    }

    /// The task the agent's terminal title names, for a lane whose row keeps
    /// the app's name.
    public var task: String? {
        metadata?.title ?? programTitle.flatMap(TerminalTitle.task(from:))
    }

    /// The name the person gave the row; it wins over every other name.
    @Published public internal(set) var customTitle: String?
    /// What the agent wrote to its session file.
    @Published public private(set) var metadata: LaneSessionMetadata?
    /// Called when the agent changes into a state that wants a person.
    var onWantsAttention: ((AgentLaneSession) -> Void)?
    /// Called when the agent's session file names a section for the lane.
    var onSectionFromAgent: ((String) -> Void)?
    private var metadataURL: URL?
    private var metadataModified: Date?

    /// The working directory with the home folder as ~.
    public var shortDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return currentDirectory.hasPrefix(home) ? "~" + currentDirectory.dropFirst(home.count) : currentDirectory
    }

    func update(lane: AgentLane) {
        self.lane = lane
    }

    func update(orphan: Bool) {
        if orphan != isOrphan { isOrphan = orphan }
    }

    func update(present: Bool, byName: Bool = false, name: String? = nil) {
        if present != isPresent { isPresent = present }
        isPresentByName = present && byName
        presenceName = isPresentByName ? name : nil
    }

    /// Take what the conversation file says.
    func update(transcript: LaneTranscript) {
        let prompts = Array(transcript.prompts.suffix(3))
        if prompts != recentPrompts { recentPrompts = prompts }
        if transcript.lastReply != lastReply { lastReply = transcript.lastReply }
        if transcript.pullRequestLinks != pullRequestLinks { pullRequestLinks = transcript.pullRequestLinks }
        if transcript.openBackgroundTasks != openBackgroundTasks { openBackgroundTasks = transcript.openBackgroundTasks }
    }

    /// Takes effect the next time the lane is attached.
    func update(backend: any LaneBackend) {
        self.backend = backend
    }

    func update(record new: LaneStatus?) {
        guard new != record else { return }
        // Only a change into a state that wants a person flags the row: the
        // first record a lane gets describes what was already so, and a poll
        // repeating the same state is not news.
        let changed = record != nil && new?.state != record?.state
        record = new
        if changed, new?.state.wantsAttention == true {
            if !isShown { needsAttention = true }
            onWantsAttention?(self)
        }
        if new?.state.wantsAttention != true { needsAttention = false }
        // A hook just fired: the moment an agent is likely to have labelled
        // its row, so look even when the row is out of sight.
        readMetadata()
    }

    /// Start the backend's process, or start it again after it ended. A
    /// running session is left alone: it is already attached.
    func start(configuration: AgentLaneStore.Configuration, font: NSFont) {
        if isAttached { return }
        if isStarted {
            view.removeInputHandling()
            view = AgentTerminalView(frame: view.frame)
        }
        isStarted = true
        hasExited = false
        generation += 1
        let view = self.view
        view.processDelegate = self
        view.font = font
        view.followAppearance()
        view.installInputHandling()
        view.getTerminal().changeHistorySize(configuration.scrollback)
        view.scrollSensitivity = configuration.scrollSensitivity
        view.registerForDraggedTypes(AgentTerminalView.droppedTypes)
        view.onShortcut = { [weak self] shortcut in self?.onShortcut?(shortcut) ?? false }
        view.shortcutResolver = { [weak self] event in self?.shortcutResolver?(event) }
        view.onOpenLink = { [weak self] url in self?.onOpenLink?(url) ?? false }
        view.onOutput = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // At most every few seconds: a busy agent prints many times a second.
                let now = Date()
                if self.lastOutputAt.map({ now.timeIntervalSince($0) > 3 }) ?? true { self.lastOutputAt = now }
            }
        }
        startProcess(configuration: configuration)
        directoryFromShell = false
        updatePoll()
    }

    /// How often an attached lane looks at its directory and session file.
    enum PollCadence {
        /// On screen or selected: the session file is read this often.
        static let visible: TimeInterval = 5
        /// Out of sight, and the shell does not report its directory.
        static let hidden: TimeInterval = 30
    }

    /// The poll interval a lane needs, or nil for none: a lane out of sight
    /// whose shell reports its own directory has nothing to poll for.
    nonisolated static func pollInterval(attached: Bool, visible: Bool, directoryFromShell: Bool) -> TimeInterval? {
        guard attached else { return nil }
        if visible { return PollCadence.visible }
        return directoryFromShell ? nil : PollCadence.hidden
    }

    private var isVisible: Bool { isShown || isSelected }

    private func visibilityChanged() {
        if isVisible { readMetadata() }
        updatePoll()
    }

    private func updatePoll() {
        guard let interval = Self.pollInterval(attached: isAttached, visible: isVisible,
                                               directoryFromShell: directoryFromShell) else {
            poll?.invalidate()
            poll = nil
            return
        }
        if let poll, poll.isValid {
            poll.setInterval(interval)
            return
        }
        poll = CadenceTimer(interval: interval) { [weak self] in
            guard let self else { return }
            if !self.directoryFromShell { self.followDirectory() }
            if self.isVisible { self.readMetadata() }
        }
    }

    private func startProcess(configuration: AgentLaneStore.Configuration) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let attachOnly = attachOnlyLaunch
        attachOnlyLaunch = nil
        let launch: TerminalLaunch
        if let attachOnly {
            launch = attachOnly
        } else {
            launch = (resumeOnStart ? backend.resumeLaunch(for: lane, shell: shell) : nil)
                ?? backend.launch(for: lane, shell: shell)
        }
        resumeOnStart = false
        var env = Self.scrubbed(ProcessInfo.processInfo.environment)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["TERM_PROGRAM"] = configuration.termProgram
        env["COLORFGBG"] = (view.colorScheme ?? .light).colorFgBg
        env["AGENTSMATE_LANE"] = lane.id
        if let url = configuration.sessionFileDirectory?.appendingPathComponent(Self.fileName(lane.id) + ".json") {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            metadataURL = url
            env["AGENTSMATE_SESSION"] = url.path
        }
        for (key, value) in configuration.environment { env[key] = value }
        for (key, value) in launch.environment { env[key] = value }
        for (key, value) in Self.hostEnvironment(for: lane) { env[key] = value }
        for (key, value) in lane.environment { env[key] = value }
        view.startProcess(executable: launch.executable, args: launch.arguments,
                          environment: env.map { "\($0.key)=\($0.value)" },
                          execName: nil, currentDirectory: launch.directory)
    }

    /// What tells the lane wrappers which host to run a lane on: nothing
    /// when ``AgentLane/host`` is nil, so they keep their own default.
    nonisolated static func hostEnvironment(for lane: AgentLane) -> [String: String] {
        guard let host = lane.host, !host.isEmpty else { return [:] }
        return ["CLAUDE_REMOTE_HOST": host, "CODEX_REMOTE_HOST": host]
    }

    /// An app started from inside another terminal or agent inherits its
    /// identity; a lane must not believe it is that pane.
    nonisolated static func scrubbed(_ environment: [String: String]) -> [String: String] {
        var env = environment
        for key in env.keys where key.hasPrefix("CMUX_") || key.hasPrefix("CLAUDE_CODE_")
            || ["TMUX", "TMUX_PANE", "CLAUDECODE", "TERM_SESSION_ID", "ITERM_SESSION_ID", "CODEX_LANE_KEY"].contains(key) {
            env.removeValue(forKey: key)
        }
        return env
    }

    static func fileName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(100))
    }

    private func readMetadata() {
        guard let url = metadataURL,
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified != metadataModified else { return }
        metadataModified = modified
        let read = LaneSessionMetadata.read(url)
        if read != metadata { metadata = read }
        if let section = read?.section { onSectionFromAgent?(section) }
    }

    private func followDirectory() {
        guard isAttached, let pid = view.process?.shellPid, pid > 0,
              let cwd = Self.workingDirectory(of: pid), cwd != currentDirectory else { return }
        currentDirectory = cwd
    }

    /// A process's current directory, from the kernel.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// End the local terminal. A backend that keeps running carries on, and
    /// opening the row attaches it again.
    func detach() {
        poll?.invalidate()
        poll = nil
        if isAttached { view.terminate() }
        view.removeInputHandling()
        if isStarted { hasExited = true }
    }

    // MARK: LocalProcessTerminalViewDelegate

    public nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    public nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in self.programTitle = trimmed }
    }

    public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        let path = url.path
        Task { @MainActor in
            self.currentDirectory = path
            if !self.directoryFromShell {
                self.directoryFromShell = true
                self.updatePoll()
            }
        }
    }

    public nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let ended = ObjectIdentifier(source)
        Task { @MainActor in
            // A late notice from a view already replaced is not this one's.
            guard ended == ObjectIdentifier(self.view) else { return }
            self.hasExited = true
            self.poll?.invalidate()
            self.poll = nil
        }
    }
}
