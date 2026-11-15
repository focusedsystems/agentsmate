import AppKit
import Combine
import SwiftTerm
import AgentsMateStatus

/// What a lane row shows: the agent's own report when its hooks have one,
/// otherwise whether the terminal here is attached.
public enum LaneDisplayStatus: Equatable, Sendable {
    case notOpened, attached, running, waitingForInput, permissionRequested, done, detached

    public var title: String {
        switch self {
        case .notOpened: "Not opened"
        case .attached: "Attached"
        case .running: "Running"
        case .waitingForInput: "Waiting for you"
        case .permissionRequested: "Asking permission"
        case .done: "Done"
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
    @Published public private(set) var isStarted = false
    @Published public private(set) var hasExited = false
    /// What the program calls itself: Claude's session name, or the shell's title.
    @Published public private(set) var programTitle: String?
    /// The shell's working directory, followed as it changes.
    @Published public private(set) var currentDirectory: String
    /// The latest record from the status feed for this lane.
    @Published public private(set) var record: LaneStatus?
    /// Set when a record that wants a person arrives while the lane is out of sight.
    @Published public private(set) var needsAttention = false
    /// Bumped on every start, so SwiftUI re-hosts the new view.
    @Published public private(set) var generation = 0
    @Published public var wantsFocus = false

    var onShortcut: ((TerminalShortcut) -> Bool)?
    private var poll: Timer?

    /// Whether the row is on screen.
    var isShown = false {
        didSet { if isShown { needsAttention = false } }
    }

    init(lane: AgentLane, backend: any LaneBackend) {
        self.lane = lane
        self.backend = backend
        self.id = lane.id
        self.currentDirectory = lane.path
        self.view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
    }

    public var isAttached: Bool { isStarted && !hasExited }

    public var status: LaneDisplayStatus {
        if let record, record.state != .ended {
            switch record.state {
            case .running: return .running
            case .waitingForInput: return .waitingForInput
            case .permissionRequested: return .permissionRequested
            case .done: return .done
            case .ended: break
            }
        }
        if !isStarted { return .notOpened }
        return hasExited ? .detached : .attached
    }

    /// The row's title: the app's name for the lane, or for a lane the
    /// person opened, what the program running in it calls itself.
    public var title: String {
        if lane.isClosable, let programTitle, !programTitle.isEmpty { return programTitle }
        return lane.title
    }

    /// The working directory with the home folder as ~.
    public var shortDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return currentDirectory.hasPrefix(home) ? "~" + currentDirectory.dropFirst(home.count) : currentDirectory
    }

    func update(lane: AgentLane) {
        self.lane = lane
    }

    /// Takes effect the next time the lane is attached.
    func update(backend: any LaneBackend) {
        self.backend = backend
    }

    func update(record new: LaneStatus?) {
        guard new != record else { return }
        let isNewer = new.map { n in record.map { n.updatedAt > $0.updatedAt } ?? true } ?? false
        record = new
        if isNewer, !isShown, new?.state.wantsAttention == true { needsAttention = true }
        if new?.state.wantsAttention != true { needsAttention = false }
    }

    /// Start the backend's process, or start it again after it ended. A
    /// running session is left alone: it is already attached.
    func start(configuration: AgentLaneStore.Configuration) {
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
        view.font = configuration.font
        view.followAppearance()
        view.installInputHandling()
        view.getTerminal().changeHistorySize(configuration.scrollback)
        view.registerForDraggedTypes(AgentTerminalView.droppedTypes)
        view.onShortcut = { [weak self] shortcut in self?.onShortcut?(shortcut) ?? false }
        startProcess(configuration: configuration)
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followDirectory() }
        }
    }

    private func startProcess(configuration: AgentLaneStore.Configuration) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let launch = backend.launch(for: lane, shell: shell)
        var env = Self.scrubbed(ProcessInfo.processInfo.environment)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["TERM_PROGRAM"] = configuration.termProgram
        env["COLORFGBG"] = (view.colorScheme ?? .light).colorFgBg
        env["AGENTSMATE_LANE"] = lane.id
        for (key, value) in configuration.environment { env[key] = value }
        for (key, value) in launch.environment { env[key] = value }
        view.startProcess(executable: launch.executable, args: launch.arguments,
                          environment: env.map { "\($0.key)=\($0.value)" },
                          execName: nil, currentDirectory: launch.directory)
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
        Task { @MainActor in self.currentDirectory = path }
    }

    public nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let ended = ObjectIdentifier(source)
        Task { @MainActor in
            // A late notice from a view already replaced is not this one's.
            guard ended == ObjectIdentifier(self.view) else { return }
            self.hasExited = true
            self.poll?.invalidate()
        }
    }
}
