import SwiftUI
import AppKit
import AgentsMateStatus

/// One Claude Code background session in a folder, as Resume Session… lists it.
struct ResumableSession: Identifiable, Equatable, Sendable {
    /// The conversation's full session id.
    var id: String
    /// The short id the daemon knows a running session by.
    var shortID: String?
    var name: String
    var directory: String
    /// Still running (working, waiting or idle), so it is attached rather
    /// than resumed.
    var isRunning: Bool
    var startedAt: Date?
}

enum ResumableSessions {
    /// The states of a session whose process is alive. `claude agents --json
    /// --all` also lists the sessions that have stopped.
    static let runningStates: Set<String> = ["working", "blocked", "done", "idle"]

    private struct Entry: Decodable {
        var id: String?
        var sessionId: String?
        var name: String?
        var cwd: String?
        var kind: String?
        var state: String?
        var startedAt: Double?
    }

    /// The background sessions of `data` (`claude agents --json --all`)
    /// working in `folder` or below it: running ones first, then the most
    /// recent. One entry per conversation.
    static func parse(_ data: Data, under folder: String) -> [ResumableSession] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        let root = LaneStatusMatch.normalizedPath(folder)
        var seen = Set<String>()
        let found: [ResumableSession] = entries.compactMap { entry in
            guard entry.kind == "background", let full = entry.sessionId ?? entry.id, !full.isEmpty,
                  let cwd = entry.cwd, case let here = LaneStatusMatch.normalizedPath(cwd),
                  here == root || here.hasPrefix(root.hasSuffix("/") ? root : root + "/"),
                  seen.insert(full).inserted else { return nil }
            let short = entry.id.flatMap { HostSessions.isValidAgentID($0) ? $0 : nil }
            let name = (entry.name?.isEmpty == false ? entry.name : nil) ?? short ?? full
            return ResumableSession(id: full, shortID: short, name: name, directory: cwd,
                                    isRunning: entry.state.map(runningStates.contains) ?? false,
                                    startedAt: entry.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        return found.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
    }

    /// Run `claude agents --json --all` on `host` (nil for this Mac) and read
    /// the folder's sessions. Nil when the list could not be had.
    static func fetch(under folder: String, host: String?, claude: String, timeout: TimeInterval = 20) async -> [ResumableSession]? {
        let script = ShellQuote.quote(claude) + " agents --json --all 2>/dev/null"
        guard let command = AgentSessionStop.command(script: script, host: host) else { return nil }
        let data: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
        guard let data, (try? JSONSerialization.jsonObject(with: data)) is [Any] else { return nil }
        return parse(data, under: folder)
    }
}

extension AgentLaneStore {
    private var claudeBackgroundBackend: ClaudeBackgroundLaneBackend? {
        availableBackends.compactMap { $0 as? ClaudeBackgroundLaneBackend }.first
    }

    /// The Mac a lane's agent runs on when it is not this one: how the lane
    /// is attached, and where its sessions are listed. Nil for this Mac.
    func remoteAgentHost(for session: AgentLaneSession) -> String? {
        let host: String?
        if listingHosts != nil, let found = sessionHost(for: session.lane) {
            host = isThisMac(found) || found == listingHosts?.selfName ? nil : found
        } else {
            host = session.backend.remoteHost(for: session.lane)
        }
        guard let host, AgentSessionStop.isValidHost(host) else { return nil }
        return host
    }

    /// Whether Resume Session… has a Claude to ask for this lane.
    func canResumeSession(_ id: AgentLane.ID) -> Bool {
        sessions[id] != nil && claudeBackgroundBackend != nil
    }

    /// Show the lane's conversations to pick one from.
    func chooseSessionToResume(in id: AgentLane.ID) {
        guard canResumeSession(id) else { return }
        resumePickerLane = id
    }

    /// What picking a row of Resume Session… does: a running session is
    /// attached, a stopped one is resumed in a new row. Nothing is stopped.
    @discardableResult
    func resume(_ choice: ResumableSession, from origin: AgentLane.ID) -> AgentLane.ID? {
        if choice.isRunning, let short = choice.shortID { return openRunningSession(short, near: origin) }
        return resumeStopped(choice, near: origin)
    }

    private func section(near origin: AgentLane.ID?) -> String? {
        origin.flatMap { id in lanes.first { $0.id == id } }.flatMap { layout.section(of: $0) }
    }

    /// Show the running background session `id`: the row that already holds
    /// it is selected, else it opens in a new row beside `origin`, attached
    /// with `claude attach <id>` on the Mac it runs on (the one `origin`
    /// runs on). The row `origin` is left as it was.
    @discardableResult
    func openRunningSession(_ id: String, near origin: AgentLane.ID?) -> AgentLane.ID? {
        guard HostSessions.isValidAgentID(id), let backend = claudeBackgroundBackend else { return nil }
        let section = section(near: origin)
        if let existing = laneHolding(sessionID: id) {
            if isDetached(existing) { adopt(existing, into: section, attach: false) }
            open(existing)
            return existing
        }
        let originSession = origin.flatMap { sessions[$0] }
        let host = originSession.flatMap(remoteAgentHost(for:))
        let records: [LaneStatus]
        if let host {
            records = hostListings[host]?.claude ?? []
        } else {
            records = (try? Data(contentsOf: backend.agentsListCache))
                .map { ClaudeAgentsList.parse($0, includeInteractive: false) } ?? []
        }
        var lane: AgentLane
        if let record = Self.record(for: id, in: records), let short = record.agentID {
            lane = Self.lane(attaching: record, shortID: short, backendID: backend.id, section: section)
        } else {
            // The refusal itself says the session runs there; the list may
            // simply not have caught up.
            lane = AgentLane(id: UUID().uuidString, title: "Session \(id)", directory: originSession?.lane.directory,
                             backendID: backend.id, isClosable: true, section: section)
            lane.agentSessionID = id
        }
        lane.host = host
        var launch: TerminalLaunch?
        if let host {
            launch = HostSessions.launch(.claude(id: id, host: host), lane: lane, shell: AgentLaneSession.loginShell,
                                         config: configuration.hostSessions ?? HostSessionsConfiguration())
            guard launch != nil else { return nil }
        }
        layout.move(lane.id, to: section)
        guard let session = add(lane, focus: true, open: false, after: origin) else { return nil }
        session.attachOnlyLaunch = launch
        open(lane.id)
        return lane.id
    }

    /// The terminal process that starts `claude --bg --resume <id>` and attaches
    /// the session that prints: here, or over ssh on `host`.
    static func resumeLaunch(for choice: ResumableSession, lane: AgentLane, host: String?,
                             backend: ClaudeBackgroundLaneBackend, config: HostSessionsConfiguration) -> TerminalLaunch {
        if let host {
            let line = ClaudeBackgroundLaneBackend.startLine(claude: config.claude, name: nil, arguments: ["--resume", choice.id])
            let remote = ShellQuote.quote(config.shell) + " -lc " + ShellQuote.quote(line)
            let ssh = "exec " + ShellQuote.quote(config.ssh) + " -t -o " + ShellQuote.quote("ConnectTimeout=\(config.connectTimeout)")
                + " -- " + ShellQuote.quote(host) + " " + ShellQuote.quote(remote)
            return TerminalLaunch(executable: AgentLaneSession.loginShell, arguments: ["-l", "-i", "-c", ssh],
                                  directory: FileManager.default.homeDirectoryForCurrentUser.path)
        }
        let claude = backend.claude.isEmpty ? "claude" : backend.claude
        let line = ClaudeBackgroundLaneBackend.startLine(claude: claude, name: nil, arguments: ["--resume", choice.id],
                                                          recordingTo: backend.startedIDFile(for: lane).path)
        return TerminalLaunch(executable: AgentLaneSession.loginShell, arguments: ["-l", "-i", "-c", line], directory: lane.path)
    }

    /// Continue a stopped conversation in a new row with `claude --bg
    /// --resume <session id>`, on the Mac `origin` runs on, and attach what
    /// that starts.
    private func resumeStopped(_ choice: ResumableSession, near origin: AgentLane.ID) -> AgentLane.ID? {
        guard ClaudeBackgroundLaneBackend.isValidConversationID(choice.id), let backend = claudeBackgroundBackend,
              let originSession = sessions[origin] else { return nil }
        let host = remoteAgentHost(for: originSession)
        let section = section(near: origin)
        var lane = AgentLane(id: UUID().uuidString, title: choice.name,
                             directory: URL(fileURLWithPath: choice.directory, isDirectory: true),
                             backendID: backend.id, isClosable: true, section: section)
        lane.sessionName = choice.name
        lane.host = host
        lane.startsNewSession = true
        let launch = Self.resumeLaunch(for: choice, lane: lane, host: host, backend: backend,
                                       config: configuration.hostSessions ?? HostSessionsConfiguration())
        layout.move(lane.id, to: section)
        guard let session = add(lane, focus: true, open: false, after: origin) else { return nil }
        session.attachOnlyLaunch = launch
        open(lane.id)
        return lane.id
    }
}

/// Resume Session…: the conversations in a lane's folder, running ones
/// marked. Type to filter, arrow keys to move, Return to choose, Escape to
/// close, as in Go to Lane….
struct ResumeSessionPicker: View {
    @ObservedObject var store: AgentLaneStore
    let laneID: AgentLane.ID
    @State private var query = ""
    @State private var sessions: [ResumableSession] = []
    @State private var loading = true
    @State private var failed = false
    @State private var highlighted: ResumableSession.ID?
    @FocusState private var fieldFocused: Bool

    private var results: [ResumableSession] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return sessions }
        return sessions.filter { session in
            let hay = (session.name + " " + (session.shortID ?? "") + " " + session.directory).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    private var chosen: ResumableSession? { results.first { $0.id == highlighted } }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Resume session", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit(choose)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .accessibilityLabel("Search sessions")
            Divider()
            if results.isEmpty {
                Text(loading ? "Looking for sessions…" : failed ? "The session list could not be read." : "No sessions in this folder.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $highlighted) {
                    ForEach(results) { session in
                        row(session).tag(session.id)
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: ResumableSession.ID.self) { _ in } primaryAction: { _ in choose() }
            }
            Divider()
            HStack {
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button(chosen?.isRunning == true ? "Attach" : "Resume", action: choose)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
            .padding(10)
        }
        .frame(width: 520, height: 400)
        .onAppear { fieldFocused = true }
        .task { await load() }
        .onChange(of: query) { _, _ in highlighted = results.first?.id }
    }

    private func row(_ session: ResumableSession) -> some View {
        HStack {
            Image(systemName: session.isRunning ? "play.circle.fill" : "clock.arrow.circlepath")
                .foregroundStyle(session.isRunning ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(session.name).lineLimit(1)
                Text(Self.detail(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(session.isRunning ? "Running" : "Stopped").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func detail(_ session: ResumableSession) -> String {
        var parts = [(session.directory as NSString).lastPathComponent]
        if let date = session.startedAt {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let lane = store.sessions[laneID], let backend = store.availableBackends
            .compactMap({ $0 as? ClaudeBackgroundLaneBackend }).first else {
            loading = false
            failed = true
            return
        }
        let claude = backend.claude.isEmpty ? "claude" : backend.claude
        let host = store.remoteAgentHost(for: lane)
        let found = await ResumableSessions.fetch(under: lane.lane.path, host: host,
                                                  claude: host == nil ? claude : (store.configuration.hostSessions?.claude ?? "claude"))
        loading = false
        failed = found == nil
        sessions = found ?? []
        highlighted = results.first?.id
    }

    private func move(_ step: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        let index = highlighted.flatMap { ids.firstIndex(of: $0) } ?? -1
        highlighted = ids[min(max(index + step, 0), ids.count - 1)]
    }

    private func choose() {
        guard let choice = chosen ?? results.first else { return }
        close()
        store.resume(choice, from: laneID)
    }

    private func close() { store.resumePickerLane = nil }
}

extension View {
    func agentLaneResumePicker(_ store: AgentLaneStore) -> some View {
        sheet(item: Binding(get: { store.resumePickerLane.map(ResumePickerRequest.init) },
                            set: { store.resumePickerLane = $0?.id })) { request in
            ResumeSessionPicker(store: store, laneID: request.id)
        }
    }
}

private struct ResumePickerRequest: Identifiable { let id: AgentLane.ID }
