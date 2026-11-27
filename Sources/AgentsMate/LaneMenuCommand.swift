import SwiftUI
import AppKit

/// A command on a lane's menu. One definition of each command's name,
/// shortcut and action serves the row's contextual menu and the menu bar's
/// Agent menu, so both list the same thing in every app.
public enum LaneMenuCommand: String, CaseIterable, Sendable {
    case open, reattach, resume, resumeHere, resumeSession, switchToClaude, switchToCodex, detach, message, markRead
    case changeIcon, rename, automaticName, pin
    case close, stop
    case copyBranch, copyPath, copySummary, copyLastPrompt, showInFinder, copySessionName

    /// The name the menu shows, for a lane in this state.
    public func title(for state: LaneMenuState) -> String {
        switch self {
        case .open: "Open \(state.laneTitle)"
        // A lane whose session does not outlive its terminal starts again
        // rather than reattaching.
        case .reattach: state.keepsRunningWhenDetached ? "Reattach" : "Start Again"
        case .resume: "Resume"
        case .resumeHere: "Resume Here (Stop Background)"
        case .resumeSession: "Resume Session…"
        // Both sit at the top of the Switch Agent submenu.
        case .switchToClaude: "Claude"
        case .switchToCodex: "Codex"
        case .detach: "Detach"
        case .message: "Message Agent…"
        case .markRead: "Mark Read"
        case .changeIcon: "Change Icon…"
        case .rename: "Rename…"
        case .automaticName: "Use Automatic Name"
        case .pin: state.isPinned ? "Unpin" : "Pin"
        // Close hides the row and ends the terminal here. Only a lane whose
        // session outlives its terminal keeps running.
        case .close: state.keepsRunningWhenDetached ? "Close (Keep Running)" : "Close"
        case .stop: "Stop Agent…"
        case .copyBranch: "Copy Branch Name"
        case .copyPath: "Copy Path"
        case .copySummary: "Copy Summary"
        case .copyLastPrompt: "Copy Last Prompt"
        case .showInFinder: "Show in Finder"
        case .copySessionName: "Copy Session Name"
        }
    }

    /// The rebindable shortcut the command is on, in both menus. ⌘W is Close
    /// Window's in the menu bar, so Close is on ⌥⌘W; a focused terminal still
    /// answers ⌘W itself.
    public var shortcutAction: LaneShortcutAction? {
        switch self {
        case .reattach: .reattach
        case .switchToClaude: .reopenClaudeRemote
        case .switchToCodex: .reopenCodexRemote
        case .message: .messageAgent
        case .close: .closeKeepRunning
        default: nil
        }
    }

    /// Whether the key works only while a lane has the keyboard, so it stays
    /// free for the app's own views otherwise.
    public var keyNeedsLaneFocus: Bool { self == .switchToClaude || self == .switchToCodex }

    /// What the command does, shown as its help tag.
    public func help(for state: LaneMenuState) -> String? {
        switch self {
        case .resume: "Continue this stopped session's conversation in this pane"
        case .resumeHere: "Stop the background session, then continue its conversation in this pane"
        case .resumeSession: "Choose a conversation from this lane's folder: a running one is attached, a stopped one resumes in a new row"
        case .switchToClaude, .switchToCodex:
            "Run this lane on the other agent. The session it was on keeps running."
        case .reattach:
            state.keepsRunningWhenDetached ? "Attach this session here" : "End this terminal and start the lane again"
        case .detach: "Close the terminal here and leave the agent running"
        case .close:
            state.keepsRunningWhenDetached
                ? "Take the row away and close its terminal here. The agent keeps running."
                : "Take the row away. This lane's agent ends with its terminal."
        case .stop:
            state.isDetached
                ? "End the agent's process; this row goes with it"
                : "End the agent's process, after asking. Its conversation resumes when the lane is opened again."
        default: nil
        }
    }
}

/// A submenu on a lane's menu.
public enum LaneMenuSubmenu: Hashable, Sendable {
    /// Folded into ``switchAgent``, which lists the same backends; no plan
    /// has it any more.
    @available(*, deprecated, message: "Reopen As is part of Switch Agent")
    case reopenAs
    /// Switch to Claude and Switch to Codex on their keys, then each backend.
    case switchAgent
    case duplicate, runOn, adopt, moveToSection, pullRequests
}

/// One entry of a lane's menu, in the order it is shown.
public enum LaneMenuItem: Hashable, Sendable {
    case command(LaneMenuCommand)
    case submenu(LaneMenuSubmenu)
    /// An Open localhost item for each port the lane listens on.
    case ports
    case divider
    /// The app's own items, after a divider (see ``LaneAction``).
    case appItems
}

/// What decides which items a lane's menu has.
public struct LaneMenuState: Equatable, Sendable {
    public var laneTitle = "Lane"
    /// A session found running with no row.
    public var isDetached = false
    public var isStarted = true
    public var isAttached = true
    public var isPinned = false
    public var needsAttention = false
    public var hasCustomName = false
    public var isClosable = true
    public var canStop = false
    public var canResume = false
    /// Resume Session… has a Claude to list this lane's folder with.
    public var canResumeSession = false
    /// The lane's session outlives its terminal, so closing or detaching leaves it running.
    public var keepsRunningWhenDetached = true
    public var hasReopenChoices = false
    public var hasRunOnHosts = false
    public var hasPullRequests = false
    public var hasPorts = false
    public var hasBranch = false
    public var hasDirectory = true
    public var summariesAvailable = false
    public var hasAppItems = false

    public init() {}
}

/// The menu: every lane menu, in every app, is this list.
public enum LaneMenuPlan {
    public static func items(_ state: LaneMenuState) -> [LaneMenuItem] {
        state.isDetached ? detachedItems(state) : laneItems(state)
    }

    /// Six groups, each under a divider: the session, the agent, the row's
    /// name and place, what to copy or open, the app's own items, and last
    /// the commands that take the row away or end its agent.
    private static func laneItems(_ s: LaneMenuState) -> [LaneMenuItem] {
        var items: [LaneMenuItem] = [.command(.open), .command(.reattach)]
        if s.canResume { items += [.command(.resume), .command(.resumeHere)] }
        if s.canResumeSession { items.append(.command(.resumeSession)) }
        items += [.command(.detach), .divider]

        items.append(.command(.message))
        if s.needsAttention { items.append(.command(.markRead)) }
        items.append(.submenu(.switchAgent))
        if s.hasRunOnHosts { items.append(.submenu(.runOn)) }
        items += [.submenu(.duplicate), .divider]

        items.append(.command(.rename))
        if s.hasCustomName { items.append(.command(.automaticName)) }
        items += [.command(.changeIcon), .command(.pin), .submenu(.moveToSection), .divider]

        if s.hasPullRequests { items.append(.submenu(.pullRequests)) }
        if s.hasPorts { items.append(.ports) }
        if s.hasBranch { items.append(.command(.copyBranch)) }
        items.append(.command(.copyPath))
        if s.summariesAvailable { items.append(.command(.copySummary)) }
        items += [.command(.copyLastPrompt), .command(.showInFinder)]

        if s.hasAppItems { items += [.divider, .appItems] }

        if s.isClosable || s.canStop { items.append(.divider) }
        if s.isClosable { items.append(.command(.close)) }
        if s.canStop { items.append(.command(.stop)) }
        return items
    }

    /// The commands at the top of the Switch Agent submenu, above its list
    /// of backends.
    public static let switchAgentCommands: [LaneMenuCommand] = [.switchToClaude, .switchToCodex]

    private static func detachedItems(_ s: LaneMenuState) -> [LaneMenuItem] {
        var items: [LaneMenuItem] = [.command(.reattach)]
        if s.canResume { items += [.command(.resume), .command(.resumeHere)] }
        items += [.submenu(.adopt), .divider, .command(.stop), .divider]
        if s.hasDirectory { items += [.command(.copyPath), .command(.showInFinder)] }
        items.append(.command(.copySessionName))
        return items
    }

    /// The commands of ``items(_:)`` in order, with Switch Agent's own
    /// commands where that submenu is.
    public static func commands(_ state: LaneMenuState) -> [LaneMenuCommand] {
        items(state).flatMap { item -> [LaneMenuCommand] in
            switch item {
            case .command(let command): [command]
            case .submenu(.switchAgent): switchAgentCommands
            default: []
            }
        }
    }
}

extension AgentLaneStore {
    /// The state a lane's menu is built from.
    func menuState(for session: AgentLaneSession, hasAppItems: Bool = false) -> LaneMenuState {
        let lane = session.lane
        var state = LaneMenuState()
        state.laneTitle = session.title
        state.isDetached = isDetached(lane.id)
        state.isStarted = session.isStarted
        state.isAttached = session.isAttached
        state.isPinned = layout.pinned.contains(lane.id)
        state.needsAttention = session.needsAttention
        state.hasCustomName = session.customTitle != nil
        state.isClosable = lane.isClosable
        state.canStop = canStop(lane.id)
        state.canResume = canResumeBackground(lane.id)
        state.canResumeSession = canResumeSession(lane.id)
        state.keepsRunningWhenDetached = session.backend.keepsRunningWhenDetached
        state.hasReopenChoices = !configuration.reopenChoices.isEmpty
        state.hasRunOnHosts = !runOnHosts(for: lane.id).isEmpty
        state.hasPullRequests = !session.displayedPullRequests.isEmpty
        state.hasPorts = !session.rowMetadata.ports.isEmpty
        state.hasBranch = session.rowMetadata.branch != nil
        state.hasDirectory = lane.directory != nil
        state.summariesAvailable = summariesAvailable
        state.hasAppItems = hasAppItems
        return state
    }

    /// The key a menu item for `command` shows and answers: its binding, and for
    /// Switch to Claude and Codex only while a lane has the keyboard.
    func menuBinding(for command: LaneMenuCommand) -> LaneKeyBinding? {
        guard let action = command.shortcutAction else { return nil }
        if command.keyNeedsLaneFocus, !(lanesHaveKeyboard && configuration.shortcuts.contains(.reopen)) { return nil }
        return shortcuts.binding(for: action)
    }

    /// Whether a lane's menu offers the command now.
    func isEnabled(_ command: LaneMenuCommand, for session: AgentLaneSession) -> Bool {
        let id = session.lane.id
        switch command {
        case .reattach: return isDetached(id) || session.isStarted
        case .resume: return !isBackgroundLive(id)
        case .resumeHere: return isBackgroundLive(id)
        case .resumeSession: return canResumeSession(id)
        // Detaching a lane whose session ends with its terminal would end it.
        case .switchToClaude: return canSwitch(id, to: .claude)
        case .switchToCodex: return canSwitch(id, to: .codex)
        case .detach: return session.isAttached && session.backend.keepsRunningWhenDetached
        case .stop: return canStop(id)
        case .copySummary: return !(session.summary?.isEmpty ?? true)
        case .copyLastPrompt: return !session.recentPrompts.isEmpty
        default: return true
        }
    }

    /// Run a menu command on a lane. Stop only asks: the person confirms it.
    func perform(_ command: LaneMenuCommand, on session: AgentLaneSession, openWindow: OpenWindowAction?) {
        let lane = session.lane
        switch command {
        case .open: open(lane.id)
        case .reattach: reattach(lane.id)
        case .resume: resumeBackground(lane.id, stoppingBackground: false)
        case .resumeHere: resumeBackground(lane.id, stoppingBackground: true)
        case .resumeSession: chooseSessionToResume(in: lane.id)
        case .switchToClaude: switchAgent(lane.id, to: .claude)
        case .switchToCodex: switchAgent(lane.id, to: .codex)
        case .detach: detach(lane.id)
        case .message: if let openWindow { _ = showMessageAgent(to: lane.id, openWindow: openWindow) }
        case .markRead: markRead(lane.id)
        case .changeIcon: menus.choosingIcon = lane.id
        case .rename: menus.rename(session)
        case .automaticName: rename(lane.id, to: nil)
        case .pin: setPinned(lane.id, !layout.pinned.contains(lane.id))
        case .close: close(lane.id)
        case .stop: menus.pendingStop = .init(id: lane.id, title: session.title)
        case .copyBranch: if let branch = session.rowMetadata.branch { Self.copyToPasteboard(branch) }
        case .copyPath: Self.copyToPasteboard(session.currentDirectory)
        case .copySummary: copySummary(of: lane.id)
        case .copyLastPrompt: copyLastPrompt(of: lane.id)
        case .showInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.currentDirectory)])
        case .copySessionName: Self.copyToPasteboard(lane.sessionName ?? lane.title)
        }
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One command of a lane's menu, as a button with its shared name, shortcut and help.
struct LaneMenuButton: View {
    @ObservedObject var store: AgentLaneStore
    @ObservedObject var session: AgentLaneSession
    let command: LaneMenuCommand
    var reveal: () -> Void = {}
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = store.menuState(for: session)
        Button(command.title(for: state)) {
            reveal()
            store.perform(command, on: session, openWindow: openWindow)
        }
        .laneShortcut(store.menuBinding(for: command))
        .disabled(!store.isEnabled(command, for: session))
        .help(command.help(for: state) ?? "")
    }
}

extension AgentLaneStore {
    /// The backend that runs `agent` for a lane: in the mode the lane is in
    /// now (a session that outlives the terminal, or run directly), else the
    /// other mode, else none.
    func switchBackendID(for id: AgentLane.ID, to agent: LaneAgentKind) -> String? {
        let current = lanes.first { $0.id == id }.flatMap { agentKind(ofBackend: $0.backendID) }
        let modes = [current?.isRemote ?? true, !(current?.isRemote ?? true)]
        for remote in modes {
            if let kind = LaneReopenChoice.Kind(agent: agent.rawValue, remote: remote), let backend = backendID(forAgent: kind) {
                return backend
            }
        }
        return nil
    }

    func canSwitch(_ id: AgentLane.ID, to agent: LaneAgentKind) -> Bool {
        sessions[id] != nil && switchBackendID(for: id, to: agent) != nil
    }

    /// Run a lane on `agent`: the row keeps its place, name and folder, and
    /// the session it was on keeps running. False when no backend runs it.
    @discardableResult
    public func switchAgent(_ id: AgentLane.ID, to agent: LaneAgentKind) -> Bool {
        guard sessions[id] != nil, let backend = switchBackendID(for: id, to: agent) else { return false }
        reopen(id, as: backend)
        return true
    }
}
