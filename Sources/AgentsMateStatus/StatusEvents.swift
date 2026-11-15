import Foundation

/// Turns what an agent hands its hooks into a ``LaneStatus``.
///
/// Claude Code passes every hook a JSON object on stdin naming the event
/// (`hook_event_name`), the conversation and its folder. Codex runs its
/// `notify` program with one JSON argument naming the event (`type`).
public enum StatusEvents {
    /// A record for one Claude Code hook call, or nil for an event that says
    /// nothing about whether the lane needs a person.
    public static func claude(hookInput data: Data, lane: String?, now: Date = Date()) -> LaneStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["hook_event_name"] as? String else { return nil }
        let message = (object["message"] as? String).map { truncate($0) }
        let state: LaneState
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "PreCompact":
            state = .running
        case "PermissionRequest":
            state = .permissionRequested
        case "Notification":
            switch object["notification_type"] as? String {
            case "permission_prompt": state = .permissionRequested
            case "idle_prompt", "elicitation_dialog": state = .waitingForInput
            case .some: return nil
            case .none:
                // Older releases send only the message.
                state = message?.localizedCaseInsensitiveContains("permission") == true
                    ? .permissionRequested : .waitingForInput
            }
        case "Stop":
            state = .done
        case "SessionStart":
            state = .waitingForInput
        case "SessionEnd":
            state = .ended
        default:
            return nil
        }
        return LaneStatus(agent: "claude", state: state, lane: lane,
                          directory: object["cwd"] as? String,
                          sessionID: object["session_id"] as? String,
                          message: event == "Notification" || event == "PermissionRequest" ? message : nil,
                          event: event, updatedAt: now,
                          transcriptPath: object["transcript_path"] as? String)
    }

    /// A record for one Codex `notify` call, or nil for an event it does not know.
    public static func codex(notifyPayload data: Data, lane: String?, now: Date = Date()) -> LaneStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let state: LaneState
        switch type {
        case "agent-turn-complete": state = .done
        case "approval-requested", "exec-approval-request", "apply-patch-approval-request": state = .permissionRequested
        case "user-input-requested": state = .waitingForInput
        default: return nil
        }
        let message = (object["last-assistant-message"] as? String) ?? (object["message"] as? String)
        return LaneStatus(agent: "codex", state: state, lane: lane,
                          directory: object["cwd"] as? String,
                          sessionID: (object["thread-id"] as? String) ?? (object["thread_id"] as? String),
                          message: message.map { truncate($0) },
                          event: type, updatedAt: now)
    }

    static func truncate(_ s: String, _ limit: Int = 200) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
