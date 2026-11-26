import SwiftUI
import AppKit
import AgentsMateStatus

/// Open a Claude Code background session as a lane from its id, pasted or
/// typed: the short id `claude --bg` prints and `claude agents` lists, or the
/// conversation's full session id. The lane attaches that session by id and
/// nothing else, so it never starts a new one.
extension AgentLaneStore {
    /// What opening a session by id came to.
    public enum OpenSessionResult: Equatable, Sendable {
        /// A row has the session now, selected and open.
        case opened(AgentLane.ID)
        /// The text holds no session id.
        case invalid
        /// No Claude background backend is registered, so nothing can attach it.
        case noBackend
        /// No running background session has the id.
        case notFound(String)
    }

    /// The session id in `text`: the last word, so a pasted `claude attach
    /// <id>` line works as well as the bare id. Nil when that is no id.
    public static func sessionID(in text: String) -> String? {
        guard let word = text.split(whereSeparator: \.isWhitespace).last.map(String.init) else { return nil }
        let id = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’()[]<>.,;"))
        if ClaudeBackgroundLaneBackend.isValidConversationID(id) || HostSessions.isValidAgentID(id) { return id }
        return nil
    }

    /// Open the background session `text` names in `section`: the row that
    /// already holds it, a Detached row adopted into the section, or a new
    /// lane attached to it by id.
    @discardableResult
    public func openSession(id text: String, in section: String?) -> OpenSessionResult {
        guard let id = Self.sessionID(in: text) else { return .invalid }
        if let existing = laneHolding(sessionID: id) {
            if isDetached(existing) { adopt(existing, into: section, attach: false) }
            open(existing)
            return .opened(existing)
        }
        guard let backend = availableBackends.compactMap({ $0 as? ClaudeBackgroundLaneBackend }).first else {
            return .noBackend
        }
        let records = (try? Data(contentsOf: backend.agentsListCache))
            .map { ClaudeAgentsList.parse($0, includeInteractive: false) } ?? []
        guard let record = Self.record(for: id, in: records), let short = record.agentID else { return .notFound(id) }
        let lane = Self.lane(attaching: record, shortID: short, backendID: backend.id, section: section)
        layout.move(lane.id, to: section)
        guard add(lane) != nil else { return .notFound(id) }
        return .opened(lane.id)
    }

    /// The row that holds `id`, as its short id or its conversation's.
    func laneHolding(sessionID id: String) -> AgentLane.ID? {
        let wanted = id.lowercased()
        return sessions.values.first { session in
            let lane = session.lane
            return [lane.agentSessionID, lane.agentConversationID, session.record?.agentID]
                .contains { $0?.lowercased() == wanted }
        }?.id
    }

    /// The running record whose short id or full session id is `id`.
    static func record(for id: String, in records: [LaneStatus]) -> LaneStatus? {
        let wanted = id.lowercased()
        return records.first { $0.agentID?.lowercased() == wanted }
            ?? records.first { $0.sessionID?.lowercased() == wanted }
    }

    /// A lane of the person's own that attaches `record` by its short id.
    static func lane(attaching record: LaneStatus, shortID: String, backendID: String, section: String?) -> AgentLane {
        let folder = record.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let title = record.lane.flatMap { $0.isEmpty ? nil : $0 } ?? folder?.lastPathComponent ?? shortID
        var lane = AgentLane(id: UUID().uuidString, title: title, directory: folder, backendID: backendID,
                             isClosable: true, section: section)
        lane.sessionName = record.lane
        lane.agentSessionID = shortID
        if let full = record.sessionID, full != shortID, ClaudeBackgroundLaneBackend.isValidConversationID(full) {
            lane.agentConversationID = full
        }
        return lane
    }

    /// Whether any backend can attach a session by id, so the command is offered.
    var opensSessionsByID: Bool { availableBackends.contains { $0 is ClaudeBackgroundLaneBackend } }

    /// Ask for a session id to open in `section`, filled in from the
    /// clipboard when it holds one.
    func askForSessionID(in section: String?) {
        menus.sessionIDText = NSPasteboard.general.string(forType: .string).flatMap(Self.sessionID(in:)) ?? ""
        menus.openingSessionIn = .init(section: section)
    }
}

/// The Open Session by ID… item for a menu that adds lanes to `section`.
struct OpenSessionByIDItem: View {
    @ObservedObject var store: AgentLaneStore
    let section: String?
    var reveal: () -> Void = {}

    var body: some View {
        if store.opensSessionsByID {
            Divider()
            Button("Open Session by ID…") {
                reveal()
                store.askForSessionID(in: section)
            }
            .help("Open a running Claude background session as a lane, from its id")
        }
    }
}
