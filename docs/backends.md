# Lane backends

A `LaneBackend` says what a lane's terminal runs and how to find its status.
The terminal always runs a process that attaches a persistent session, so
closing the app, or opening the same lane in another terminal or on another
device, never starts a second conversation.

## Command lanes (`CommandLaneBackend`)

A command run in an interactive login shell. `CommandLaneBackend.tmuxLane`
runs a wrapper that attaches a tmux session named after the folder, passing the
folder as the last argument. Status comes from hooks (see `status-feed.md`).
This is the default backend for both Claude Code and Codex lanes.

Its `renameCommand` is `/rename %@` for a Claude Code or Codex lane, so renaming
the lane renames the agent's session too (see the README). Set it to nil for a
wrapper whose agent should keep its own name.

## Claude Code background sessions (`ClaudeBackgroundLaneBackend`)

Opt-in. Claude Code 2.1.325 runs sessions in its own daemon:

- `claude --bg -n <name> [prompt]` starts the full session in the background,
  with its hooks and remote control.
- `claude attach <name>` draws it in a terminal. Two terminals attached at once
  stay in step. Closing the terminal leaves the session running.
- `claude agents --json` lists background sessions and the interactive ones
  already running, with name, folder, pid and state.

The backend attaches the session named after the lane's folder, starting it
first when there is none. `ClaudeAgentsStatusSource` reads its state from
`claude agents --json`; add it to a `LaneStatusFeed`'s `sources`. It has no
`renameCommand`: the session's name is how every device attaches it, so
renaming a lane leaves it alone.

### Could it replace tmux for Claude lanes?

For lanes on the Mac the app runs on, yes:

- Attach, detach and multi-terminal lockstep behave like tmux.
- Status needs no hooks: the daemon reports `working`, `blocked` and `done`.
- Remote control works without a wrapper.

What keeps tmux the default for now:

- **Other machines.** A tmux lane can live on another Mac and be attached over
  ssh from anywhere; a background session is local to its daemon. Remote
  attach would need `ssh -t <host> claude attach <name>`, which has not been
  tested.
- **Terminal size.** When two attached terminals differ in size, the smaller
  one's rendering garbles; tmux resizes to the smallest client.
- **Trust.** A background session's folder must already be a trusted workspace.
- **Codex has no equivalent**, so Codex lanes stay on tmux whatever Claude uses.
- **`blocked` is coarse.** It covers both a permission prompt and a question,
  so hooks are still needed to tell them apart.

Switching an app is one change: register `ClaudeBackgroundLaneBackend` and set
its Claude lanes' `backendID` to it.

## Stopping lanes and orphans

A backend that can end its session sets `canStop` and implements `stop`:
`ClaudeBackgroundLaneBackend` runs `claude stop`, and a `CommandLaneBackend`
runs its `stopCommand` (killing the tmux session, say). The lane's menu gains
Stop Lane. The conversation is kept, so opening the lane resumes it.

Closing a row never stops its session unless the app turns on
`closeStopsLane`, which is off by default: the session outlives the row as it
outlives the app, and shows in the Detached section until it is attached
again or stopped.

Add a `LanePresenceSource` (`TmuxPresenceSource` lists tmux sessions with
their attached-client counts) to the status feed, and turn on
`highlightsOrphans`. Then a lane whose session runs with nothing attached
anywhere is drawn as an orphan, so a stray can be reattached or stopped.
Leave it off where lanes are kept running on purpose.

## Finding lane sessions with no row

`LaneBackend.discoverSessions()` returns the backend's own lane sessions
running now, for the store's Detached section (see the README). It returns
nothing by default, and a backend must never list sessions that are not its
lanes. The store calls it at launch and about every ten minutes (stretched
fourfold while the app is in the background, in Low Power Mode or hot), one
backend at a time, skipping a sweep while the last is still going.

Give a tmux lane backend its naming so it can list and attach by name:

```swift
CommandLaneBackend.tmuxLane(id: "claude", displayName: "Claude", command: "my-lane-wrapper",
                            statusAgent: "claude",
                            tmuxSessions: TmuxLaneSessions(prefixes: ["lane-"],
                                                           sessionName: { "lane-" + $0.title }))
```

`prefixes` (or `matches`) decides which sessions are lanes. With neither,
nothing is listed. `isRelevant`, in place of both, decides from the whole
`DiscoveredSession`: its name and the folder its active pane is in
(`#{pane_current_path}`). It is for wrappers whose session names carry no
prefix, where only the folder tells the app's lanes from everything else on the
tmux server. `ClaudeBackgroundLaneBackend.isRelevant` does the same for
background sessions, whose folder is the `cwd` in `claude agents --json`.
Neither rule starts a process; the folder comes with the listing. `sessionName`, when the app knows how its wrapper names a
lane's session, makes rows and sessions match by name instead of by folder.
Listing is one `tmux list-sessions` at background priority with a five-second
timeout, through the package's two shared helper slots.

A lane found this way carries `sessionName`. Its terminal runs
`tmux attach-session -t =<name>` (an exact match), falling back to the
wrapper when the session has ended, and Stop runs `tmux kill-session -t =<name>`.

## Lanes on another machine (untested)

`TmuxLaneSessions.host`, off by default, puts a tmux backend's lanes on
another machine reached over ssh. It has not been tried on real machines yet;
treat it as a starting point.

```swift
TmuxLaneSessions(prefixes: ["lane-"], host: "user@build-host", remoteTmux: "/opt/homebrew/bin/tmux")
```

- A lane whose session name is known runs
  `ssh -t -o ConnectTimeout=5 -- <host> '<tmux> attach-session -t =<name>'`.
  Any other lane runs its wrapper command on the host the same way, so the
  wrapper must be on the host's PATH for an ssh command.
- The host is passed after `--`, and must look like a host name, `user@host`
  or an address: a leading dash, spaces, quotes or shell characters are
  refused, and the lane prints why instead of connecting. The remote command
  is quoted once for the host's shell and again for the local one.
- `remoteTmux` is the tmux on the host. An ssh command does not read the
  login shell's PATH there, so a full path is often needed.
- Discovery over ssh happens only when the host is set: the same
  `list-sessions` in `BatchMode`, so it never prompts, at the same slow
  cadence with a timeout of the connect timeout plus ten seconds. It needs an
  ssh agent the app can reach without a shell, such as the system one.
- Stop runs `tmux kill-session` on the host by name. The app's own
  `stopCommand` runs locally, so it is not used for host lanes.
- Status hooks run on the host and write its status folder, not this Mac's,
  so host lanes show no status unless the app brings those records over.

## Room for more

A backend that serves models from elsewhere (local models on other machines,
say) conforms to the same protocol: its `launch` attaches whatever keeps that
conversation alive, and it reports status through the feed folder or a
`LaneStatusSource`.
