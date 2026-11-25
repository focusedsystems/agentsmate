# Session owner

When several apps built on AgentsMate list the same session, only one of them
notifies about it: a notification, a Dock badge count and a sound. The others
show the session and its state, silently, and leave it out of their Dock badge.
The one that notifies is the app the person last worked in for that session.

## The file

`<state home>/agentsmate/session-owner.json`, one per user, where the state home
is `$XDG_STATE_HOME` when that is an absolute path and `~/.local/state`
otherwise. It maps a session key to the app that last claimed it:

```json
{"ab12cd34": {"app": "com.example.app", "at": "2026-11-25T18:00:00Z", "created_by": "com.example.app"}}
```

- The key is the agent's session id, else the tmux session name, else the lane's folder. An app that knows both an id and a tmux name writes both keys.
- `created_by` is optional: the app that made the session.
- Writes take a lock on `session-owner.json.lock`, go to a temporary file and are renamed into place. The file is mode 600 and its folder 700.
- A reader treats the file as empty when it is missing, bigger than 1 MB, not owned by the user, writable by group or others, a symbolic link, or not JSON. It skips an entry it cannot read.
- A claim counts for 30 days. An entry is dropped after 180.

The path is `AgentLaneStore.Configuration.sessionOwnerFile`; nil turns the gate off. `ownerAppID` overrides the bundle id the app records itself under.

## Who claims

An app claims a session when the person works in it there: selects it, clicks or types in its terminal, pastes, sends it a message, attaches it, or creates or duplicates its lane. Viewing it on the All Agents board, restoring the selection at launch and showing the lanes again claim nothing.

## Who notifies

Before posting a notification, or counting a session in the Dock badge, an app asks who owns the session. In order:

1. The lane is not shared (`Configuration.isLaneShared` says no, or is not set): this app. Behaviour is unchanged.
2. A claim in the file: that app.
3. The app that created the session, from `created_by`.
4. The lowest bundle id among this app and the other apps whose `displayed.json` lists the session.

The notification path reads the file again just before posting, so a handoff the file watcher has not yet seen still counts. When the file changes, an app that lost a session removes that session's delivered notification and drops it from its badge.

## Checking it

Each row of `displayed.json` carries `owner_app`, the answer above as this app sees it. No two apps should show themselves as the owner of the same session.
