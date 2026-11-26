# Shared lanes

An app opened on any Mac can show the same lanes, each attaching the same
session, when the Macs share a hosts registry. One Mac, the hub, holds a lane
list per app. Every other Mac reads and writes that list over ssh. Without the
registry, nothing changes: each Mac keeps its own lanes and its own Last
Session restore.

## Hosts registry

AgentsMate reads two files in `~/.config/agent-hosts/` and never writes them.

`hosts.conf` lists one host per line. Each line holds a name, a role and a
platform, and `#` starts a comment:

```
hub-mac    hub     mac
laptop     client  mac
mini-1     lane    mac
```

- `hub` holds the shared lists and runs lanes by default. There is exactly one.
- `lane` can run lanes.
- `client` only opens apps and attaches to lanes.

A name is an ssh host alias, so `ssh <name>` must work from every Mac.

`self` holds one line: this Mac's name from `hosts.conf`.

Sharing is on when both files are there, a hub is listed, and the app is an
app bundle with a bundle identifier. `AgentLaneStore.Configuration.sharedLanes`
defaults to `SharedLaneSettings.automatic()`. Set it to nil to turn sharing off.
A test runner or command-line tool is not an app bundle, so it never reaches
a hub.

## The list

The hub keeps each app's list at
`~/.local/state/agentsmate/<bundle id>/lanes.json`:

```json
{
  "version": 1,
  "restore": true,
  "lanes": [
    {
      "id": "6F1C…",
      "title": "Docs 2",
      "directory": "~/Developer/docs",
      "backendID": "claude",
      "command": "claude-remote",
      "variantFlag": "-n",
      "variant": "2",
      "host": "mini-1",
      "section": "Work",
      "pinned": null,
      "icon": null,
      "tint": null,
      "sessionName": null,
      "agentSessionID": null,
      "overlay": null,
      "order": 3,
      "updated": "2026-01-02T03:04:05Z"
    }
  ],
  "closed": [{ "id": "9A0B…", "at": "2026-01-02T03:05:00Z" }]
}
```

Each lane field works as follows:

- `id` is the lane's identity. It never changes, and it is the lane's
  `$AGENTSMATE_LANE`. Two lanes in one folder are two ids and two variants.
- `title` is the name the person gave the row. Null means the automatic name.
- `directory` is written with `~` for the home folder.
- `command` and `variantFlag` are set when the backend is a
  `CommandLaneBackend` that passes the folder, so a lane can be started without
  the app: `<command> [<variantFlag> <variant>] <directory>`.
- `variant` is null for the first lane in a folder.
- `host` is null for a lane on the hub.
- `icon` and `tint` are the icon (`LaneIcon.stringValue`) and the `#RRGGBB`
  colour the person chose.
- `sessionName` and `agentSessionID` name the session an adopted row attaches,
  so another Mac attaches the same one.
- `overlay` is true for a row the app lists itself (one its own registry
  defines, or a session found running): the entry only carries its name, icon,
  colour, pin or section, and never makes a row on another Mac.
- `restore` (on the list, not a lane) is false when the list only mirrors rows
  between Macs. A tool that restarts sessions after a reboot must skip it
  whole. `SharedLaneSettings.restores` sets it, and once any copy says false
  the merged list stays false.
- `updated` and `at` are UTC times to the second.

Every key is written, including the null ones.

## Merging

Every write reads the list, merges it, and writes it back:

- Lanes merge by `id`. The newer `updated` wins.
- A lane whose `closed` time is at or after its `updated` stays closed, so a
  Mac that has not synced for a while cannot bring it back.
- A close older than seven days, or older than the lane it names, is dropped.

The hub writes to a temporary file beside the list and renames it over the
list. Another Mac reads the list with
`ssh -o BatchMode=yes -o ConnectTimeout=5 <hub> cat <path>`. It writes by
piping the list to `mkdir -p <dir> && cat > <path>.tmp.$$ && mv <path>.tmp.$$ <path>`
on the hub, with the same ssh options.

A lane's `updated` changes only when this Mac changed the lane: its name,
icon, colour, section, pin, host or folder, or where it sits in the list. A lane unchanged here takes the hub's copy, so a
rename on one Mac reaches the others.

### The first sync

A Mac that meets a row for the first time merges it, so no row is lost and no
Mac's rows win outright:

- A row only this Mac has is added, stamped with when this Mac last changed
  its layout.
- A row both Macs have, with the same content, is left alone.
- A row both Macs have, with different content, takes the fields of the copy
  edited later. A Mac with no edit time on record loses ties to the list's
  copy. The row is pinned when either copy was.

Syncing only mirrors the list. It never starts, attaches, stops or renames a
session: a row another Mac added waits, unstarted, until it is shown, and a
host change from another Mac is taken without restarting a terminal that is
attached.

## When it syncs

A sync runs at each of these times:

- at launch, after the Last Session restore
- when the app becomes active
- every 30 seconds while the app is active
- one second after a lane is added, closed, renamed, duplicated, moved or
  pinned, or a section changes

A sync that would change nothing writes nothing.

Each sync applies the merged list to the sidebar:

- Lanes another Mac opened are added. They wait, unstarted, until they are
  shown.
- Lanes closed on another Mac leave the sidebar. Their sessions are never
  stopped: only the terminal on this Mac ends.
- Names, sections, pins and hosts changed on another Mac are taken, unless the
  lane changed here during the sync.

The list as last synced is cached at
`~/Library/Caches/<bundle id>/shared-lanes.json`. If the hub cannot be reached
at launch, the app shows the cached lanes on top of its own Last Session
restore.

## Restore keeps every lane

The workspaces file records each lane's `id`, `host`, `command` and
`variantFlag` next to its `variant`. A restore reuses the saved id and skips
only a lane whose id is already open, so duplicates in one folder come back
as separate lanes with their own sessions, and `$AGENTSMATE_LANE` stays the
same from launch to launch. A lane saved before ids were kept is still matched
by folder and backend, as before.

## Run On

When the registry is there, a lane whose backend is a lane wrapper gets a
Run On submenu, in its context menu and in the Agent menu. The submenu lists
the hub and every `lane` host, with a checkmark on the one the lane runs on.
Picking a host records it as the lane's `host` (the hub is recorded as null)
and restarts the lane's terminal if it is attached.

A lane with a host gets `CLAUDE_REMOTE_HOST` and `CODEX_REMOTE_HOST` set to
it in its terminal's environment. The wrapper reads them to pick where the
session runs. A lane with no host gets neither, so the wrapper uses its own
default, which should be the hub.

Run On is not offered for a backend whose `tmuxSessions.host` is fixed,
because that backend runs its wrapper over ssh itself.
