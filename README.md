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
Every Mac showing the same lanes, and running a lane on another host:
[docs/shared-lanes.md](docs/shared-lanes.md).

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

## Usage meter

`Configuration.usageSources` fills the meter at the sidebar's foot.
`KeyValueUsageFileSource` reads the `KEY=VALUE` file a status-line helper
writes. A window whose reset has passed is left out, and a file older than an
hour (`maxAge`) counts for nothing, so an agent with no current reading shows
as "Usage unknown" rather than with old figures. On a Mac whose agents all run
elsewhere, `KeyValueUsageCommandSource` reads the same form from a command the
app supplies, such as `ssh` to the Mac that writes the file. It runs at most
every five minutes, at background priority with a timeout, and doubles the
wait after each failure, up to an hour. AgentsMate does not fetch the figures
itself: the service that reports them wants the account's web sign-in, which
a package has no business holding.

```swift
KeyValueUsageCommandSource(agent: "Claude",
                           command: ["/usr/bin/ssh", "-o", "BatchMode=yes", "--", host, "cat .usage-cache"])
```

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
`gh pr view --json title,state,number,isDraft,headRefName -- <url>` with the person's own
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
ledger already has it. When the ledger already tracks a pull request whose head
(`PullRequestDetails.headBranch`) is the folder's branch, in the repository the
folder's `origin` points at, the row takes it from the ledger and `gh` is not
asked about the branch at all. `store.recordPullRequests(_:for:)` adds links an
app learns of another way.

## Links in the terminal

⌘-click a link in a lane's terminal to open it: an OSC 8 hyperlink, or a plain
`http://` or `https://` URL printed in the output. A plain URL is found on the
row that was clicked only, ends at whitespace, quotes or angle brackets, and
drops trailing punctuation and closing brackets it did not open. Holding ⌘
shows an OSC 8 link's target before the click.

Set `store.onOpenLink` to route links yourself. It gets the URL and the lane
it was clicked in, and returns whether the app handled it:

```swift
store.onOpenLink = { url, laneID in
    guard url.host == "code.example.com" else { return false }
    showInApp(url, from: laneID)
    return true
}
```

When it returns false or is nil, `http`, `https` and `mailto` links open in the
default app. Any other scheme, `file:` included, reaches the hook and nothing
else. `TerminalLinks` has the parsing and scheme rules for an app that wants
them.

## Renaming the agent's session

Renaming a lane (`store.rename(_:to:)`) also renames the agent's own session
when its backend has a `renameCommand`: a format with `%@` for the name.
`CommandLaneBackend` sets `/rename %@` when its `statusAgent` or its command's
program is `claude` or `codex`, and nil otherwise; set the property to change
it or turn it off. `ClaudeBackgroundLaneBackend` has none, because its lanes
attach their session by name.

The command is typed only when it cannot disturb anything:

- the lane is attached here and the agent has the terminal;
- the agent is not running a turn or asking permission; and
- the agent's input line reads as empty.

The input line is read from the screen under the cursor
(`AgentPromptLine`). Claude Code's `❯` between two rules, its older `│ >` box,
and Codex's `›` are known; dim text after the marker is a placeholder. Text
after the cursor, a second line of input, a menu, a screen scrolled back, or any
other layout means nothing is typed, and the row says why for a few seconds
(`session.renameNotice`). The text goes in first and Return follows 150 ms
later in a write of its own, because a remote pane drops a Return sent with
the text. Restoring a workspace and duplicating a lane name the row only.

The person's switch is `AgentsModeKeys.renameAgentSession` ("Rename the agent's
session too" in `AgentLaneSettingsSection`), on by default and shown when a
registered backend can rename. `store.renameAgentSession(_:to:)` sends the
command by itself and returns an `AgentRenameOutcome`.

## Lanes that survive anything

### Detached sessions

At launch, and then about every ten minutes, the store asks each backend for
the lane sessions it can see (`LaneBackend.discoverSessions()`). A session no
row attaches goes into a Detached section at the foot of the list, as a row
that has not been started. A backend lists only its own lane sessions, never
everything a tmux server or daemon holds:

- `CommandLaneBackend` lists nothing unless it has `tmuxSessions`, and then
  only the tmux sessions whose names start with one of its `prefixes` (or that
  its `matches` rule accepts).
- `ClaudeBackgroundLaneBackend` lists Claude Code's background sessions from
  the `claude agents --json` list every app shares, never interactive ones.
  `isLaneSession` narrows it; `discoversSessions = false` turns it off.

Where a lane's name carries no mark of its own, its folder says whose it is.
Both backends take an `isRelevant` rule that sees the whole
`DiscoveredSession`, its name and its folder, in place of the name rule, and
`DiscoveredSession.isInside(anyOf:)` keeps the sessions working in the app's
folders or anywhere below them. The rule runs off the main actor, so the app
hands it folders it can read from any thread, here `appFolders()`:

```swift
TmuxLaneSessions(isRelevant: { $0.isInside(anyOf: appFolders()) })
```

A row claims a session by the name its backend knows it by
(`LaneBackend.sessionName(for:)`, `TmuxLaneSessions.sessionName`), else by the
name its status matches, else by folder. A row on a backend that did not list
the session claims it by name only, so a wrapper lane that attaches a tmux
session or a Claude Code background session of the same name keeps it out of
Detached, while a Codex lane in the same folder as a Claude one does not.

A row also holds a session whose own id it knows, whatever either is named:
the id its status is matched by (`LaneStatusMatch.session`, which a
`sessionIDFile` gives) or the one its status record carries. Claude Code
background sessions carry their ids, so a wrapper that starts one under a name
of its choosing keeps it out of Detached. A Claude row that knows no id holds
the one background session working in its folder, when there is exactly one.
When a row attaches, it is matched against the last sweep at once and again a
moment later, once its wrapper has recorded the session, so a Detached row for
the same session goes then rather than at the next sweep.

### Closing a row leaves its session running

Closing a row ends its terminal here and nothing else: the session it attached
keeps running, shows in the Detached section, and is the same conversation
when it is opened again. Stop Session (or Stop Lane) is what ends it.
`Configuration.closeStopsLane` turns on stopping at close for an app that wants
closing to work like closing a tmux workspace; it is off by default.

A Detached row's menu, and the Agent menu for the selected one:

- **Reattach** attaches the session in place; the row stays in Detached.
  Clicking the row does the same.
- **Adopt Into Section** moves it into a section, attaches it, and keeps it
  as a lane of the person's own, so the restore snapshot and workspaces
  record it with its session's name (`AgentLane.sessionName`).
- **Stop Session** ends it, where the backend can (tmux by name, `claude stop`).

Detached rows are left out of the restore snapshot and workspaces; the next
launch finds them again. `Configuration.findsDetachedSessions` (on by default)
turns the sweep off, and `store.sweepForDetachedSessions()` runs one now.

### A restore snapshot that is always current

Once the app has run `restoreAtLaunch()` or `performLaunchBehavior()`, the
store writes the restore snapshot by itself about two seconds after the lanes,
the selection or what is attached changes, on a background queue, with an
atomic replace of the workspaces file. A crash or a reboot then reopens what
was open. `saveRestore()` at quit still writes it at once.

The snapshot (`store.restoreSnapshot()`) holds the lanes the person opened
that are attached here, plus those a restore brought back that have not been
shown yet, and marks the selected one. "Reopen the lanes open at quit" keeps
its meaning: it decides whether that snapshot is reopened at launch.

## Sections and navigation

Every section header has a + menu listing the registered agents. Choosing one
asks for a folder, then starts a lane there in that section and selects it;
cancelling changes nothing. The chooser opens at the selected lane's folder
when it is in that section, else the section's first lane's.
`Configuration.chooseFolder` supplies the chooser; the default is an
`NSOpenPanel` sheet (`AgentLaneStore.chooseFolderWithOpenPanel(startingAt:)`),
and an app can offer its own recent folders or repositories instead. A folder
another lane of that agent already uses gets a session of its own
(`AgentLane.variant`), so the new lane never attaches the old one's
conversation. The same items are in the header's menu as New Lane in Section,
and in the Agent menu for the selected lane's section. The first header keeps
the app's accessory beside its +. Code can do the same with
`store.newLane(in:backendID:)`.

Every group folds, the lanes in no section included
(`LaneLayout.unsectionedKey`, `LaneGroup.collapseKey`). Collapse Other
Sections, in the header's menu, the Sort and Sections menu and the Agent
menu, folds every group but one (`store.collapseOtherSections(than:)`).
Rename Section edits the name in the header: Return or clicking away keeps it,
⎋ puts it back. Drag a header onto another to put that section before it
(`store.moveSection(_:before:)`); Move Section Up and Down stay in the menu for
the keyboard.

Search matches a lane's name, folder, summary and recent prompts, and the name
of its section: a section whose name matches shows all its lanes, opened for
the search without changing how it was folded.

Beside Active, Running and Needs You, an Idle chip shows the lanes that are
alive but neither working nor waiting for the person; the chips are also
toggles under Show Only in the Sort and Sections menu. Chips that would leave
the list empty turn themselves off: when a lane stops running under Running,
or when a new chip cannot be combined with the others, in which case the new
one stays. Only a search that matches nothing leaves the Show All overlay.

`AgentLaneHistoryButtons(store:)` is a Back and Forward pair for the app's
toolbar, on the same history as the Agent menu's Back and Forward:

```swift
.toolbar { ToolbarItem(placement: .navigation) { AgentLaneHistoryButtons(store: store) } }
```

## Reopen As

Reopen As restarts the selected lane on another agent. Each choice the app
offers has a kind, and each kind has the same rebindable shortcut in every
app:

| Kind            | Default |
| --------------- | ------- |
| Same Agent      | ⌥⌘R     |
| Claude (remote) | ⇧⌘C     |
| Codex (remote)  | ⇧⌘X     |
| Claude (direct) | ⌥⇧⌘C    |
| Codex (direct)  | ⌥⇧⌘X    |

An app maps its own backends onto the kinds. `.sameAgent()` starts the lane's
current agent again in a fresh terminal:

```swift
reopenChoices: [
    .sameAgent(),
    LaneReopenChoice("Claude (remote)", backendID: "claude-remote", kind: .claudeRemote),
    LaneReopenChoice("Codex (direct)", backendID: "codex", kind: .codexDirect),
]
```

The keys belong to the lanes only while a lane's terminal or the lane list
has the keyboard (`store.lanesHaveKeyboard`). Then they win over the app's
own uses of the same keys; anywhere else the app keeps them, and the menu
items show no shortcut. The Agent menu carries the items, disabled while no
lane is selected. An app with a menu of its own puts `LaneReopenMenu(store:)`
there. A store takes the keys when its `Configuration.shortcuts` contains
`.reopen`, which `.fixedLanes` and `.all` both do.

## Copy and Paste in the terminal

While a terminal has the keyboard, ⌘C copies its selection and ⌘V pastes
before the menu bar or any view sees the keys, so an app's own menus and
shortcuts cannot swallow them. Edit › Copy and Paste reach the terminal too.
Shift-drag selects text when the program has the mouse.

⌘V pastes what is on the clipboard the way Terminal does: copied files go in
as their quoted paths, text as a paste, and an image on its own as Ctrl+V,
which Claude Code and Codex both take as "read the image from the
clipboard". The agent reads its own Mac's clipboard, so an image reaches a
session attached over ssh only when that Mac's clipboard has it too (through
Universal Clipboard, for example); copied files paste as local paths, which
the other Mac may not have.

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
