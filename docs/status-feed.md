# Lane status feed

Each lane's state comes from the agent itself. A hook or notify program writes
one small JSON record per lane into a shared folder, and every app that uses
AgentsMate reads that folder.

| State | Written when |
|---|---|
| `running` | A prompt was submitted or a tool ran, or the turn ended with a background shell still running |
| `waitingForInput` | The session started, the agent opened a question dialog, or its turn ended on a question |
| `permissionRequested` | The agent stopped on a permission prompt |
| `done` | The agent finished its turn without asking anything |
| `ended` | The agent process exited |

## How a turn ends

The end of a turn (Claude Code's `Stop`, Codex's `agent-turn-complete`) is
read for what the agent is actually doing:

1. If the last reply ends on a question, the state is `waitingForInput` and
   the record's `message` is that question.
2. Otherwise, if a background shell the agent started is still running, the
   state stays `running`. The agent wakes when the shell finishes, and its
   next `Stop` settles the state.
3. Otherwise the state is `done`.

A reply ends on a question when its last line of text, after code blocks and
trailing whitespace are set aside, ends in a question mark. The check is
deliberately narrow: a quote, table row, heading, inline code or link at the
end does not count, and neither does a question followed by anything else.

Claude Code's `Stop` hook sends the last reply (`last_assistant_message`) and
the background work in flight (`background_tasks`). Releases that leave either
out are covered by reading the end of the conversation file named in
`transcript_path`; nothing else in the hook reads the transcript. Codex sends
its last reply as `last-assistant-message`, and its turns are not held open by
background shells.

Claude Code's idle reminder, sent about a minute after a turn ends
(`Notification` with `idle_prompt`), writes nothing: the lane keeps the state
its turn ended with, and no attention is raised for it.

## Folder

`$AGENTSMATE_STATUS_DIR`, else `$XDG_STATE_HOME/agentsmate/lanes`, else
`~/.local/state/agentsmate/lanes`. A record is replaced whole on every write.
Its file is named after the agent and its lane: the tmux session it runs in, or outside tmux `$CLAUDE_LANE` (set by a background-session launcher) or `$AGENTSMATE_LANE` (set by the app), so one lane
has one file whichever device attached it last.

## Record

```json
{
  "agent" : "claude",
  "state" : "permissionRequested",
  "lane" : "my-project",
  "directory" : "/path/to/my-project",
  "sessionID" : "0e249dbf-…",
  "message" : "Claude needs your permission to use Bash",
  "event" : "Notification",
  "updatedAt" : "2026-11-15T19:04:11Z"
}
```

## Install the writer

Build the writer and put it on your PATH.

```sh
swift build -c release --product agentsmate-status
install .build/release/agentsmate-status ~/.local/bin/
```

## Claude Code hooks

Add `agentsmate-status claude` as a command hook on `SessionStart`,
`UserPromptSubmit`, `PostToolUse`, `Notification`, `Stop` and `SessionEnd` in
`~/.claude/settings.json`. Each entry looks like this one:

```json
{ "hooks": [ { "type": "command", "command": "agentsmate-status claude" } ] }
```

## Codex notify

Codex runs one `notify` program with the event's JSON as its last argument.
Set `agentsmate-status codex` as that program; to keep a notify program you
already use, put it after `--then` and it receives the same payload.

```toml
notify = ["agentsmate-status", "codex", "--then", "/path/to/your-existing-notifier"]
```

Codex reports the end of a turn, and approval requests where the release sends
them, so a Codex lane shows `done` and `permissionRequested` but not `running`.

## Conversation files

Apps read each lane's conversation file with `LaneTranscript` for its recent
prompts, last reply, the pull requests the agent linked and the background
shells it has running. A Claude Code record names its file in
`transcriptPath`; a Codex lane's file is found under `$CODEX_HOME/sessions`
(default `~/.codex/sessions`) by its thread id. The reader keeps its place in
the file and parses only what was appended, and the store looks only at files
whose size or modification time changed: every 5 seconds while the lanes are
on screen and every 30 seconds otherwise, at background priority and slower
still while the app is in the background.

## Matching records to lanes

A `CommandLaneBackend` with a `statusAgent` matches the newest record from that
agent whose folder is the lane's folder and which came from inside a tmux
session. A conversation started by hand in the same folder never colours a lane.
An app can set `AgentLane.statusMatch` to `.lane("<tmux session>")` to match by
name instead.

A lane whose session a presence source lists (a tmux session, say), or which
a daemon's session list reports, is alive: it counts as active in the Active
filter before anyone opens it here.

When a lane's command records which agent session it attached, set
`sessionIDFile` on the backend to that file. Status is then matched by session
id, which survives renames and tells apart lanes that share a folder; the
folder match is used only while the file is missing.

## Notes from scripts

A script running in a lane can describe its own work on the lane's row: a
line of text, how far along it is, and log lines shown in the row's tooltip.

```sh
agentsmate-status note --text "Running migrations" --progress 0.4
```

```sh
agentsmate-status note --log "Applied 0007_add_index"
```

```sh
agentsmate-status note --clear
```

The lane is found the way the hooks find it; `--lane <name>` names it
outside one. Notes sit beside the records in a `notes` folder and are dropped
after a day without an update.
