import SwiftUI
import AgentsMateStatus

/// What a lane row says at a glance: where its session runs, how it runs,
/// and which agent is in it. Everything comes from data the store already
/// has (the backend, the lane's host against this Mac, the agent kind), so
/// the sidebar rows, All Agents cards and `displayed.json` agree.
public struct LaneBadges: Equatable, Sendable {
    public enum HostKind: String, Sendable { case local, remote }
    public enum RunKind: String, Sendable { case tmux, bg, terminal }

    public var hostKind: HostKind
    /// The host's name, when the lane's session has one.
    public var hostName: String?
    public var runKind: RunKind
    /// `claude`, `codex`, another agent's id, or nil for a plain shell or command.
    public var agent: String?

    public init(hostKind: HostKind, hostName: String? = nil, runKind: RunKind, agent: String? = nil) {
        self.hostKind = hostKind
        self.hostName = hostName
        self.runKind = runKind
        self.agent = agent
    }

    /// The run kind a backend's `displayed.json` kind (`tmux`, `claude-bg`,
    /// `command`, `shell`, or its own id) stands for.
    public static func runKind(forBackendKind kind: String) -> RunKind {
        switch kind {
        case TmuxLaneSessions.kind: .tmux
        case ClaudeBackgroundLaneBackend.kind: .bg
        default: .terminal
        }
    }

    public var agentName: String {
        switch agent {
        case "claude": "Claude"
        case "codex": "Codex"
        case let other?: other.prefix(1).uppercased() + other.dropFirst()
        case nil: "Shell"
        }
    }

    public var runName: String {
        switch runKind {
        case .tmux: "tmux"
        case .bg: "background"
        case .terminal: "terminal"
        }
    }

    public var hostLabel: String {
        switch (hostKind, hostName) {
        case (.local, nil), (.remote, nil): hostKind == .local ? "this Mac" : "remote"
        case (.local, let name?): "\(name) (this Mac)"
        case (_, let name?): name
        }
    }

    /// "Claude · background · mac-desktop": the tooltip and the spoken label.
    public var summary: String {
        [agentName, runName, hostName ?? (hostKind == .local ? "this Mac" : "remote")].joined(separator: " · ")
    }

    static func symbol(forAgent agent: String?) -> String? {
        switch agent {
        case "claude": "asterisk"
        case "codex": "curlybraces"
        case nil: nil
        default: "sparkle"
        }
    }

    var hostSymbol: String { "desktopcomputer" }

    var runSymbol: String {
        switch runKind {
        case .tmux: "rectangle.split.2x1"
        case .bg: "moon.zzz"
        case .terminal: "terminal"
        }
    }
}

/// The one mark at the end of a row's metadata line: a globe on a lane that
/// runs on another Mac, with where, how and which agent in its tooltip and
/// spoken label. A lane on this Mac carries no mark.
struct LaneBadgeStrip: View {
    let badges: LaneBadges

    var body: some View {
        HStack(spacing: 5) {
            if badges.hostKind == .remote {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 12)
                    .help("Runs on \(badges.hostLabel) · \(badges.summary)")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badges.summary)
    }
}

extension AgentLaneStore {
    /// The agent in a lane: its Reopen As kind, or Claude for a background
    /// session; nil for a plain shell.
    func laneAgent(_ lane: AgentLane) -> String? {
        agentKind(ofBackend: lane.backendID)?.agent
            ?? (backend(id: lane.backendID) is ClaudeBackgroundLaneBackend ? "claude" : nil)
    }

    /// The badges for a lane's row.
    func laneBadges(for lane: AgentLane) -> LaneBadges {
        let backend = self.backend(id: lane.backendID)
        let host = sessionHost(for: lane) ?? backend.flatMap(DetachedSessions.laneHost) ?? lane.host ?? liveSelfName
        return LaneBadges(hostKind: isThisMac(host) ? .local : .remote,
                          hostName: host.flatMap { $0.isEmpty ? nil : $0 },
                          runKind: LaneBadges.runKind(forBackendKind: backendKind(backend, id: lane.backendID)),
                          agent: laneAgent(lane))
    }
}
