# AgentsMate

Agents mode for macOS apps: a sidebar of agent lanes and a live terminal for
each, inside the app. Every lane attaches a persistent session (a tmux lane, or
a Claude Code background session), so the conversation open in the app is the
same one other terminals and devices see.

- **`AgentsMate`**: `AgentLaneStore`, `AgentsModeView`, `AgentLaneCommands`,
  the SwiftTerm view, and the lane backends.
- **`AgentsMateStatus`**: the lane status feed, without AppKit.
- **`AgentsMateChat`**: a headless `claude -p` stream-json conversation.
- **`agentsmate-status`**: the Claude Code hook and Codex notify writer that
  feeds lane status. See [docs/status-feed.md](docs/status-feed.md).

macOS 14 or later. SwiftTerm is held below 1.12, whose Metal shaders do not
build with the Command Line Tools alone.

## Use

Add the package pinned to a revision:

```swift
.package(url: "https://github.com/focusedsystems/agentsmate.git", revision: "<commit>")
```

Create one store for the app, register its backends, and give it lanes:

```swift
let store = AgentLaneStore(
    configuration: .init(termProgram: "MyApp", defaultsPrefix: "agents."),
    backends: [CommandLaneBackend.tmuxLane(id: "claude", displayName: "Claude",
                                           command: "my-lane-wrapper", statusAgent: "claude")])
store.sync(lanes: [AgentLane(id: "docs", title: "Docs", symbol: "book",
                             directory: docsFolder, backendID: "claude")])
```

Show it with `AgentsModeView(store:labels:empty:)` and add
`AgentLaneCommands(store:)` to the scene's commands.

Backends and the case for each: [docs/backends.md](docs/backends.md).

## Licence

MIT.
