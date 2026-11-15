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
`claude agents --json`; add it to a `LaneStatusFeed`'s `sources`.

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

## Room for more

A backend that serves models from elsewhere (local models on other machines,
say) conforms to the same protocol: its `launch` attaches whatever keeps that
conversation alive, and it reports status through the feed folder or a
`LaneStatusSource`.
