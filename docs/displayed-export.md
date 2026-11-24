# The displayed export

`displayed.json` says what an app's sidebar and All Agents board show right
now. It holds only what the app shows: a lane its `sessionScope` keeps out
never becomes a row, and a lane the search or the status chips hide is left
out, as it is on screen. Schema version 1.

The file is `<state home>/agentsmate/<bundle id>/displayed.json`, where the
state home is `$XDG_STATE_HOME` when that is an absolute path and
`~/.local/state` otherwise. The folder is mode 700 and the file mode 600. It
is written to a temporary file and renamed, so a reader never sees half of one.
It is rewritten about a second after the first change, and only when the
content differs from the last write. The app encodes and writes off the main
actor. It is not rewritten on a timer, so `written_at` is the time of the last
change, not a heartbeat.

Every key is always present; a value that is absent is `null`. Times are
ISO 8601 UTC.

```json
{"schema_version": 1,
 "app": {"bundle_id": "com.example.app", "version": "1.2", "build": "34", "agentsmate_commit": null},
 "written_at": "2026-11-23T18:00:00Z",
 "last_discovery_finished_at": "2026-11-23T17:59:50Z",
 "filter": {"show": "active", "statuses": [], "search": null, "sidebar_search": null},
 "counts": {"needs_you": 0, "working": 1, "idle_or_done": 0},
 "rows": [
  {"section": "Group A", "title": "Lane one", "lane_id": "lane-1", "backend": "claude-bg", "agent": "claude",
   "session_id": "ab12cd34", "attached_session_id": "ab12cd34", "session_name": null, "host": "host-a",
   "folder": "/work/repo", "state": "working", "attached": true, "selected": false,
   "is_parallel": false, "is_top_level": true, "collapsed": false, "column": null}],
 "all_agents": []}
```

## Fields

- `app`: the bundle id, version and build, and the AgentsMate commit when the app says it.
- `last_discovery_finished_at`: when the last sweep for sessions came back; null before the first.
- `filter.show`: `active` (only running sessions) or `all`. `filter.statuses` lists the chips that are on: `active`, `running`, `needs_you`, `idle`, `unread`. `filter.search` is All Agents' search text and `filter.sidebar_search` the sidebar's.
- `counts`: the All Agents header badges, over every lane before search and chips.
- `rows`: the sidebar's rows in sidebar order, Pinned first and Detached last.
- `all_agents`: the cards All Agents shows, column by column, with the same fields.

A row:

- `section`: the heading it sits under; null when the list has no headings, or for lanes in no section.
- `title`, `lane_id`.
- `backend`: `tmux`, `claude-bg`, `command`, `shell`, or the backend's own id.
- `agent`: `claude`, `codex`, or null.
- `session_id`: the id the row is meant to attach (a background session's short id).
- `attached_session_id`: the id actually running in the row, from its status record: the short id, else the conversation id; null when unknown. The two are in the same form only for a background session, so compare them only then.
- `session_name`: the tmux session name the row attaches.
- `host`, `folder`.
- `state`: `active` (attached here), `working`, `needs_you` (waiting or asking permission), `idle` (idle or done), `not_attached`, `stopped` (its terminal ended).
- `attached`: whether the terminal here is attached. `selected`: the row is the open one (never while All Agents is showing).
- `is_parallel`: a session found for a lane's folder, shown beside or under that lane. `is_top_level`: false when it is indented under its lane.
- `collapsed`: its section is folded, so the sidebar does not draw the row until it is opened. Such rows are listed.
- `column`: null in `rows`; in `all_agents`, `needs_you`, `working`, `idle_or_done` or `not_running`. A card's `section` is its area and its `selected` is false.

## Reading and comparing

`agentsmate-status displayed [--app <bundle id>] [--file <path>] [--json]` prints the file;
`--app` can be left out when exactly one app has one. With
`--compare <live-sessions.json>` it also lists:

- snapshot sessions that are not done and that no row or card shows, matched by the app lane id the watcher recorded, the short id, or the tmux name, on the same host. An app's scope is code, so it cannot be evaluated from the file: every unmatched session is listed, unless `--scope <folder>` (repeatable) limits the list to those folders.
- rows or cards whose state is `active`, `working` or `needs_you` but whose session the snapshot does not list.

The exit status is 0 when nothing differs, 1 when something does, and 2 when a file cannot be read.
