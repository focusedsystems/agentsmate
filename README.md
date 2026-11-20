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

An agent can label its own row: each lane's environment has
`AGENTSMATE_SESSION`, a path where it may write `{"title": "…", "section": "…"}`.
A name the person gives the row wins over that, which wins over the task in the
agent's terminal title.

Backends and the case for each: [docs/backends.md](docs/backends.md).

## Summaries

Set `Configuration.summaryModel` (such as `"haiku"`) to give each row a one-line
summary that leads with the work, then where it stands: "Billing export: CSV
writer done, upload step next". Each lane is summarised by its own agent, as a
short call on the person's own account:

- Claude lanes run `claude -p --model <summaryModel>` with no tools, MCP
  servers, hooks, slash commands or saved session, and only local settings.
- Codex lanes run `codex exec --ignore-user-config --ephemeral --sandbox
  read-only` with hooks and the shell tool off, at low reasoning effort, on
  `Configuration.codexSummaryModel` (nil is Codex's default model).

Both run at background priority in an empty folder with a clean environment
and a timeout. At most two run at once. A lane is summarised again when a new
prompt arrives, and at most every three minutes while only the reply changes.
A failure (not signed in, a rate limit, a missing CLI) pauses that agent's
summaries for ten minutes. Summaries are kept in
`~/Library/Caches/<bundle id>/agent-summaries.json` (`summaryCacheFile`), with
fingerprints of the prompt and reply they came from and no conversation text,
so a relaunch shows the last line at once. Apps can add or replace a summarizer
for an agent with `Configuration.summarizers` and the `LaneSummarizing`
protocol.

`AgentLaneSettingsSection` shows a "Summarize sessions" switch while
`summaryModel` is set, saved under `AgentsModeKeys.summarizeSessions` and on by
default; `store.summariesEnabled` is the same switch. Nil `summaryModel` keeps
summaries off whatever the switch says.

`Configuration.rowStyle` picks the row layout. `.standard` (the default) keeps
the name first and shows the summary as the status line while the agent is not
working. `.summaryFirst` leads every row with the summary and puts the name in
semibold beneath it. Search matches the summary and the person's recent
prompts, the row's hover adds the agent's last reply, and the row's menu and
the Agent menu have Copy Summary and Copy Last Prompt.

## Inbox and messaging

`AgentInboxView` lists every lane that has stopped for the person. Asking You
holds the lanes asking a question or permission and any lane whose
notification has not been read; Finished holds the lanes that ended a turn and
the ones a daemon's session list reports idle. Each row shows the lane's
summary, what the agent last said, and the pull requests it posted as chips.
Double-click a row or press Return to show its lane. Mark Read and Mark All
Read are on the row's menu, the inbox toolbar and the Agent menu
(`store.markRead(_:)`, `store.markAllRead()`). Chips open through
`store.onOpenPullRequest`, or the default browser when it is nil.

Put the inbox in a `Window` scene and give its id to the store, and the
sidebar's foot gets an inbox button with a badge counting Asking You, beside
the usage meter:

```swift
Window("Agent Inbox", id: "inbox") { AgentInboxView(store: store) { _ in showAgents() } }
AgentMessageWindow(store: store)
```

```swift
AgentLaneStore.Configuration(termProgram: "MyApp", inboxWindowID: "inbox",
                             messageWindowID: AgentMessageWindow.defaultID)
```

Message Agent (⌥⌘K, rebindable as `.messageAgent`) is in the Agent menu and
on every row's menu. With `messageWindowID` set it opens `AgentMessageWindow`:
a target picker that starts on the selected lane, a message field where Return
sends and Option-Return starts a new line, and ⎋ to close. Without it, the
sidebar's alert does the same job. Sending types the text into the lane's
terminal and presses Return. A lane not attached here is attached in the
background first (`store.attachInBackground(_:)`), without moving the
selection or the keyboard, and the text waits until its agent takes a paste.
If nothing takes it within 20 seconds it goes on the clipboard instead.
`store.message(_:to:)` is the same send for an app's own surfaces.

## Keeping the agent CLIs current

The `AgentsMateUpdates` product finds the Claude Code and Codex command-line
tools, works out how each was installed (Homebrew cask or formula, npm global,
or the Claude native installer) and updates it with that same tool. It never
installs a CLI that is absent, never uses sudo and never prompts. A CLI installed
some other way is reported, not touched.

Create one model with a place to save its state and a defaults key, start it, and
put the section in a Settings form:

```swift
let updates = AgentCLIUpdateModel(
    stateURL: supportFolder.appendingPathComponent("cli-updates.json"),
    keepCurrentKey: "agents.keepCLIsCurrent")
updates.start()

Form { AgentCLIUpdatesSection(model: updates) }
```

The first check runs 20 seconds after `start()`, then every six hours. While
`keepCurrent` is on, give each agent process `launchEnvironment(for:)` and
`launchArguments(for:)` so it does not also update itself.

## Lane icons

A lane's icon is an SF Symbol or one of 258 bundled SVG icons. Set
`AgentLane.icon` (`.symbol("hammer")` or `.bundled("rocket")`); `AgentLane.symbol`
still works and is used when `icon` is nil. People change it from a lane's
contextual menu, "Change Icon…", which opens `LaneIconPicker`: search, a switch
between SF Symbols and the bundled set, a keyboard-navigable grid, and a colour
row with a custom colour. The choice is kept in `LaneLayout` and wins over the
app's. To keep it in the app's own model too, set
`store.onIconChange = { lane, icon, tintHex in … }`; `icon.stringValue` is
`sf:hammer` or `svg:rocket`, and `LaneIcon(_:)` reads it back. Draw an icon
anywhere with `LaneIconView(icon:tintHex:size:)`.

## Licence

MIT.

The bundled icons are from [Lucide](https://lucide.dev) (`lucide-static`),
licensed ISC, copyright Lucide Icons and Contributors. The licence text is in
`Sources/AgentsMate/Resources/LaneIcons/LICENSE-lucide.txt`.
