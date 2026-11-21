import Foundation

/// Turns what an agent hands its hooks into a ``LaneStatus``.
///
/// Claude Code passes every hook a JSON object on stdin naming the event
/// (`hook_event_name`), the conversation and its folder. Codex runs its
/// `notify` program with one JSON argument naming the event (`type`).
public enum StatusEvents {
    /// A record for one Claude Code hook call, or nil for an event that says
    /// nothing new about whether the lane needs a person.
    ///
    /// `Stop` looks at how the turn ended: a last reply that ends on a
    /// question is `waitingForInput` with the question as its message, a
    /// background shell still running keeps the lane `running`, and anything
    /// else is `done`. The hook's own `last_assistant_message` and
    /// `background_tasks` are used when it sends them; otherwise `transcript`
    /// reads the end of the conversation file. The sixty-second idle reminder
    /// (`idle_prompt`) returns nil, so the lane keeps the state it had.
    public static func claude(hookInput data: Data, lane: String?, now: Date = Date(),
                              transcript: (String) -> LaneTranscript? = { LaneTranscript.tail(path: $0) }) -> LaneStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["hook_event_name"] as? String else { return nil }
        var message = (object["message"] as? String).map { truncate($0) }
        let state: LaneState
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "PreCompact":
            state = .running
        case "PermissionRequest":
            state = .permissionRequested
        case "Notification":
            switch object["notification_type"] as? String {
            case "permission_prompt": state = .permissionRequested
            case "elicitation_dialog": state = .waitingForInput
            // A reminder that the turn ended a while ago, not news.
            case "idle_prompt": return nil
            case .some: return nil
            case .none:
                // Older releases send only the message.
                if message?.localizedCaseInsensitiveContains("permission") == true {
                    state = .permissionRequested
                } else if message?.localizedCaseInsensitiveContains("waiting for your input") == true {
                    return nil
                } else {
                    // Anything else is a reminder or an announcement, not a
                    // block on the person.
                    return nil
                }
            }
        case "Stop":
            let end = turnEnd(object, transcript: transcript)
            state = end.state
            message = end.message
        case "SessionStart":
            // A session that just started sits idle at its prompt. Nobody
            // is blocking on a person, so it is not waiting for input.
            state = .done
        case "SessionEnd":
            state = .ended
        default:
            return nil
        }
        return LaneStatus(agent: "claude", state: state, lane: lane,
                          directory: object["cwd"] as? String,
                          sessionID: object["session_id"] as? String,
                          message: ["Notification", "PermissionRequest", "Stop"].contains(event) ? message : nil,
                          event: event, updatedAt: now,
                          transcriptPath: object["transcript_path"] as? String)
    }

    /// A record for one Codex `notify` call, or nil for an event it does not know.
    public static func codex(notifyPayload data: Data, lane: String?, now: Date = Date()) -> LaneStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let state: LaneState
        switch type {
        case "agent-turn-complete":
            let last = object["last-assistant-message"] as? String
            if let question = last.flatMap(LaneTranscript.finalQuestion(in:)) {
                return LaneStatus(agent: "codex", state: .waitingForInput, lane: lane,
                                  directory: object["cwd"] as? String,
                                  sessionID: (object["thread-id"] as? String) ?? (object["thread_id"] as? String),
                                  message: truncate(question), event: type, updatedAt: now)
            }
            state = .done
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

    /// How a Claude Code turn ended, from the `Stop` hook's input and, for
    /// what it leaves out, the end of the transcript.
    static func turnEnd(_ object: [String: Any], transcript: (String) -> LaneTranscript?) -> (state: LaneState, message: String?) {
        let hookReply = object["last_assistant_message"] as? String
        let hookTasks = object["background_tasks"] as? [[String: Any]]
        var read: LaneTranscript?
        if hookReply == nil || hookTasks == nil, let path = object["transcript_path"] as? String, !path.isEmpty {
            read = transcript(path)
        }
        let question = hookReply.map(LaneTranscript.finalQuestion(in:)) ?? read?.question
        if let question { return (.waitingForInput, truncate(question)) }
        let shells: Int
        if let hookTasks {
            shells = hookTasks.filter { task in
                task["type"] as? String == "shell" && !LaneTranscript.isFinished(task["status"] as? String ?? "running")
            }.count
        } else {
            shells = read?.openBackgroundTasks.count ?? 0
        }
        return shells > 0 ? (.running, nil) : (.done, nil)
    }

    static func truncate(_ s: String, _ limit: Int = 200) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
