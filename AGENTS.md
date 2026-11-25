# AgentsMate

A public Swift package that gives a macOS app an Agents mode: a sidebar of
agent lanes and a live terminal for each. Everything here is public and
permanent, commit messages and pull requests included.

## Rules

- **Nothing app-specific.** No personal, employer or app-internal detail: no
  paths, hostnames, command names of anyone's private scripts, area names, or
  organisations. Apps inject lanes, commands and environment through
  `AgentLane`, `LaneBackend` and `AgentLaneStore.Configuration`.
- **Lanes attach persistent sessions.** A backend attaches a session that
  outlives the app (a tmux lane, a Claude Code background session), so the
  same conversation is reachable from other terminals and devices. Do not
  replace that with an in-process agent SDK.
- **Status comes from the agents.** Lane state is written by Claude Code hooks
  and Codex `notify` through `agentsmate-status`, or read from a daemon's own
  session list. Do not infer it from terminal output or bells.
- **SwiftTerm stays below 1.12** (its Metal shaders do not build with the
  Command Line Tools). macOS 27 minimum, Swift 6 language mode.
- **UI follows the mac-arsed-mac-app conventions**: native controls, every
  command in a menu and a contextual menu, full keyboard coverage, saved state.

## Working

Work in a worktree at `./.worktrees/<name>` off `origin/main`, build and test
(`swift build && swift test`), and land changes through a pull request; main is
never pushed directly. Apps follow main through their own sync workflows, so a
breaking API change needs the matching change in each app.
