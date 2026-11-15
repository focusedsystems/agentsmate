# Lane status feed

Each lane's state comes from the agent itself. A hook or notify program writes
one small JSON record per lane into a shared folder, and every app that uses
AgentsMate reads that folder.

| State | Written when |
|---|---|
| `running` | A prompt was submitted or a tool ran |
| `waitingForInput` | The agent is idle at its prompt or asking a question |
| `permissionRequested` | The agent stopped on a permission prompt |
| `done` | The agent finished its turn |
| `ended` | The agent process exited |

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

## Matching records to lanes

A `CommandLaneBackend` with a `statusAgent` matches the newest record from that
agent whose folder is the lane's folder and which came from inside a tmux
session. A conversation started by hand in the same folder never colours a lane.
An app can set `AgentLane.statusMatch` to `.lane("<tmux session>")` to match by
name instead.

When a lane's command records which agent session it attached, set
`sessionIDFile` on the backend to that file. Status is then matched by session
id, which survives renames and tells apart lanes that share a folder; the
folder match is used only while the file is missing.
