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
`store.onOpenPullRequest`, or the default browser when it is nil. Transcript
text is written by the agent, so a link is collected and opened only when
`PullRequestLink.isTrusted(_:)` accepts it: `https`, a GitHub or Azure DevOps
host exactly, no user, password, port, query or fragment, and a pull request
path.

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

## Pull request ledger

Every pull request link an agent posts is kept in its lane's ledger, for
GitHub and Azure DevOps links that `PullRequestLink.isTrusted(_:)` accepts. The
ledger outlives the conversation and the app: it is saved to
`~/Library/Caches/<bundle id>/agent-pull-requests.json`
(`Configuration.pullRequestLedgerFile`, nil keeps it in memory), holds the
newest twenty links per lane, and drops a lane that gained no link for thirty
days. `session.pullRequests` lists them, oldest first, as `LanePullRequest`
values with a number, title, state and repository once looked up.

A `PullRequestResolver` looks a link up. The package ships
`GitHubPullRequestResolver`, which runs
`gh pr view --json title,state,number,isDraft -- <url>` with the person's own
`gh` sign-in, at background priority with a fifteen-second timeout. Apps add
others, such as one for Azure DevOps or a GitHub Enterprise host, with
`Configuration.pullRequestResolvers`; the first whose `canResolve(_:)` accepts
a link answers it, and the built-in one is asked last. A link no resolver takes
is kept and shown by number only.

A new link is looked up as soon as it is read. Open and draft pull requests are
asked about again every five minutes, on a timer that runs only while one is
open and backs off with the rest of the package. Merged and closed ones are
final and never asked about again. At most two lookups run at once, and a
resolver that fails is left alone for ten minutes, keeping what it said last.

Claude Code keeps its own pull request status cache, `gh-pr-status-cache.json`
in its config folder. When it is there it is read once at launch as a warm
start for GitHub links (`Configuration.pullRequestSeedFile`, nil skips it).

The inbox's chips and the sidebar row's chips show each pull request's state as
a colour and a symbol: green open, grey draft, purple merged, red closed. The
row shows the newest two and counts the rest, its hover lists them all, and the
row's and the inbox's menus have a Pull Requests submenu that opens each one
through `store.open(_:)`, which uses `store.onOpenPullRequest` like the chips
do. The pull request `gh` finds for the folder's branch (`showsRowMetadata`)
still shows for a lane whose agent has not posted it, and is left out when the
ledger already has it. `store.recordPullRequests(_:for:)` adds links an app
learns of another way.

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
