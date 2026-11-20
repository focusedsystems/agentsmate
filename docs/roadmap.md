# Roadmap

What AgentsMate still lacks for an agent-first terminal app, and how each piece
fits the package. Every phase lands as one AgentsMate pull request, then a
small change in each app that turns it on. Apps pick features up through
`AgentLaneStore.Configuration` and settings keys, and the package carries no
app-specific detail.

## Phase 0: one transcript reader

Status, summaries and the pull request ledger all need the same facts from an
agent's transcript. Today `TranscriptDigest` reads the last 512 KB for prompts
and a last reply, and only Claude records carry a `transcriptPath`.

- Add `LaneTranscript` to `AgentsMateStatus`: an incremental reader that keeps
  its byte offset and parses only what was appended since the last read.
- It yields `prompts`, `lastReply`, `pullRequestLinks`, `openBackgroundTasks`
  (background shells started and not yet finished) and `endsOnQuestion`.
- It reads both Claude Code JSONL and Codex session JSONL.
- Codex `notify` gives no transcript path. Find the file under
  `$CODEX_HOME/sessions` by its `thread-id`.
- The store reads transcripts off the main actor every five seconds, only for
  lanes whose file grew.

## Phase 1: status that matches what the agent is doing

`StatusEvents` maps hooks one-to-one, so a turn that ends on a question shows
Finished, and Claude's sixty-second idle reminder shows Needs You.

- `Stop`: if the transcript ends on a question, the state is `waitingForInput`
  with the question as the message. If a background shell is still open, the
  state stays `running`. Otherwise the state is `done`.
- The idle reminder (`idle_prompt`) leaves the state as it was and raises no
  attention.
- Codex `agent-turn-complete` gets the same question check on
  `last-assistant-message`.
- A lane found alive by a presence source counts as active before anyone opens
  it.
- Tests use recorded hook payloads and transcript fixtures for each case.

## Phase 2: summaries

`LaneSummarizer` runs `claude -p` for every lane, caches in memory, and has no
switch.

- A `LaneSummarizing` protocol with two implementations: Claude
  (`claude -p --model <m> --no-session-persistence --tools ""`) and Codex
  (`codex exec --ephemeral --sandbox read-only`). Each lane is summarised by
  its own agent.
- At most two run at once. A summary regenerates when a new prompt arrives, or
  at most every three minutes while only the reply changes. A failure (not
  signed in, rate limit, no CLI) pauses that agent's summaries for ten minutes.
- Cache to `Caches/<bundle id>/agent-summaries.json` so a relaunch shows the
  last line at once.
- Add a "Summarize sessions" settings key to `AgentLaneSettingsSection`.
- Rows can lead with the summary and show the name in semibold beneath
  (`Configuration.rowStyle`). Search matches the summary and recent prompts.
- The row's hover adds the agent's last reply. The row menu gains Copy Summary
  and Copy Last Prompt.

## Phase 3: inbox and messaging

- Inbox: Mark Read, double-click to show, summary and pull request chips, and
  unread notifications counted under Asking You. Polled idle lanes count as
  Finished.
- An inbox button with a badge in the sidebar footer, beside the usage meter.
- Message Agent becomes a small window scene (`AgentMessageWindow`) instead of
  an alert, on a `.messageAgent` shortcut action. The app picks the default key,
  since ⇧⌘K is often taken.
- Sending still types the text and presses Return in the lane's terminal. A
  lane not attached here is attached in the background first, so it can be
  messaged from anywhere.

## Phase 4: pull request ledger

- `LaneTranscript` collects pull request URLs from the agent's replies, for
  GitHub and Azure DevOps.
- `PullRequestResolver` is a protocol. The package ships a `gh` resolver. An
  app injects others, such as one for Azure DevOps, so no organisation detail
  lives here.
- Open PRs are rechecked every five minutes. Merged and closed ones are final
  and never rechecked.
- The UI shows chips in the inbox, a Pull Requests submenu on the row, and the
  list in the row's hover. The branch-based chip stays for lanes whose agent
  has not posted a link.

## Phase 5: rename reaches the agent

- Renaming a lane whose backend says it can (`LaneBackend.renameCommand`, e.g.
  `/rename %@` for Claude Code) also sends that command to the agent.
- It is sent only when the agent's input line is empty. The terminal buffer's
  cursor row is read for this, so a half-typed prompt is never touched.
- Add a "Rename the agent's session too" settings key, on by default.

## Phase 6: lanes that survive anything

- A launch sweep lists the lane-prefixed sessions a backend can see (tmux,
  Claude background sessions). It adds any that have no row to a Detached
  section, with Reattach and Adopt actions.
- The restore snapshot is written whenever the lane list changes (debounced),
  not only at quit, so a crash or reboot keeps it.
- The tmux backend gains an optional lane host, `ssh -t <host> tmux attach -t …`,
  so lanes on another machine can be attached. This needs real testing before
  it is on by default.

## Phase 7: sections and navigation polish

- A "+" on every section header. It picks an agent, then a folder (the app
  supplies the chooser), and creates the lane in that section.
- Collapse Other Sections. Search matches section names. Rename sections
  inline. Reorder sections by dragging.
- An Idle filter chip. Filters clear themselves when they would hide
  everything.
- Optional toolbar Back and Forward buttons as an accessory the app can place.

## Not planned

- Split layouts and panel templates per lane. A lane is one terminal. Apps
  that want several panes open several lanes.
- Mirroring the lane list between devices. Lanes are persistent sessions, so
  other devices already reach them.
