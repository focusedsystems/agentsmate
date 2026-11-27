# Ask

The dashboard has an Ask field, "Ask about your lanes…", focused with ⌘K from
Agent ▸ Ask About Lanes…. Type a question such as "which lane was I fixing the
login bug in?" and press Return. A spinner shows while it searches, and Cancel
(or Escape) stops it. Each answer is a row with its title, Mac, folder, last
active time and the reason it fits, and Open (⌘↩ for the top row, or double
click) shows it.

AgentsMate does not search anything itself. It runs a command that does, so the
command decides which Macs, transcripts and lane lists to look through.

## The command

By default the command is `lane-find`. It is looked up on `PATH`, then
`~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, since an app started
from the Dock has a short `PATH`. Set another name with the `askCommand` default
or the `AGENTSMATE_ASK_COMMAND` environment variable; a name is a bare file name,
never a path. When the command is missing the panel says so.

It is run as `<command> --json -- <question>` with no shell. It must print one
JSON object and exit 0 with answers or 1 with none. Anything else is shown as an
error with the text it wrote to standard error. It is ended on Cancel, and after
150 seconds, and AgentsMate leaves no session or process behind.

```json
{
  "question": "which lane was I fixing the login bug in?",
  "llm": true,
  "hosts_skipped": ["offline-mac"],
  "results": [
    {
      "rank": 1,
      "host": "mac-one",
      "agent": "claude",
      "lane_id": "6F1C…",
      "app": "com.example.app",
      "session_id": "11111111-2222-3333-4444-555555555555",
      "cwd": "/Users/me/Developer/login",
      "last_active": "2026-11-27T22:36:17Z",
      "title": "Login bug",
      "why": "One sentence naming the evidence.",
      "evidence": "A short excerpt with secrets removed.",
      "work_items": ["TASK-123"]
    }
  ]
}
```

`host`, `agent`, `lane_id`, `app`, `session_id`, `cwd` and `last_active` drive
Open; every field but `host` may be null or absent. A row with no `host` is
dropped.

## What Open does

- A board card already shows the lane or session: it opens that card, which
  selects the lane in its app.
- Otherwise, when `app` names an installed app and `lane_id` is set: the app is
  started if needed and asked to show that lane, which reattaches or resumes it
  the way the app does for any lane.
- Otherwise the conversation is resumed in Terminal on its own Mac
  (`claude --resume` or `codex resume`, in its folder, over ssh for another
  Mac). Session ids, folders and host names are checked before they reach a
  shell, and a row that fails the check cannot be opened.
