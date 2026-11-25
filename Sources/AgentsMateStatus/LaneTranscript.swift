import Foundation

/// What an agent's conversation file says, kept current by reading only what
/// was appended since the last read.
///
/// Reads Claude Code transcripts (`~/.claude/projects/…/<session>.jsonl`) and
/// Codex session files (`$CODEX_HOME/sessions/…/rollout-…-<thread>.jsonl`).
/// The reader keeps its byte offset and any half-written last line, so each
/// ``update()`` parses only new records. A value type: move it to a
/// background task, update it there, and hand it back.
public struct LaneTranscript: Equatable, Sendable {
    /// A background shell the agent started and has not seen finish or stop.
    public struct BackgroundTask: Equatable, Hashable, Sendable {
        /// The agent's id for the task, as its notices and stop calls name it.
        public var id: String
        /// The tool call that started it.
        public var toolUseID: String?
        /// The agent's own description of the command, or its start.
        public var description: String?

        public init(id: String, toolUseID: String? = nil, description: String? = nil) {
            self.id = id
            self.toolUseID = toolUseID
            self.description = description
        }
    }

    public let path: String
    /// How far into the file has been read.
    public private(set) var offset: UInt64 = 0
    /// The person's prompts, oldest first; at most ``promptLimit``.
    public private(set) var prompts: [String] = []
    /// The text of the agent's last reply.
    public private(set) var lastReply: String?
    /// The title the person gave a Claude conversation (`/rename`), the last
    /// one written to the file. Nil when it was never renamed.
    public private(set) var sessionTitle: String?
    /// GitHub and Azure DevOps pull request links from the agent's replies,
    /// in the order they first appeared.
    public private(set) var pullRequestLinks: [URL] = []
    /// Background shells started and not yet finished or stopped, oldest first.
    public private(set) var openBackgroundTasks: [BackgroundTask] = []

    /// Whether nothing has happened since the last reply: no tool call, no
    /// new prompt, no new turn.
    public private(set) var replyIsLast = false

    /// The question the conversation ends on, if its last reply ends on one.
    public var question: String? {
        replyIsLast ? lastReply.flatMap(Self.finalQuestion(in:)) : nil
    }

    /// Whether the agent's last reply ends on a question to the person.
    public var endsOnQuestion: Bool { question != nil }

    static let promptLimit = 20
    static let promptLength = 4000
    static let replyLength = 64 * 1024
    static let linkLimit = 100

    /// Where to start in a file read for the first time: this many bytes
    /// from its end. Nil reads it all.
    public let window: UInt64?
    private var started = false
    private var remainder = Data()
    private var size: UInt64?
    private var modified: Date?
    private var inode: UInt64?
    /// Background Bash calls whose result has not arrived yet, by tool call id.
    private var pendingStarts: [String: String?] = [:]
    /// Output reads in flight (older Claude Code), by tool call id: the task read.
    private var pendingReads: [String: String] = [:]

    /// A reader for `path`. A file read for the first time is read from
    /// `window` bytes before its end, so a long conversation costs only its
    /// tail; pass nil to read everything.
    public init(path: String, window: UInt64? = 1024 * 1024) {
        self.path = path
        self.window = window
    }

    /// The last `bytes` of a conversation, read once.
    public static func tail(path: String, bytes: UInt64 = 256 * 1024) -> LaneTranscript? {
        var transcript = LaneTranscript(path: path, window: bytes)
        guard transcript.update() else { return nil }
        return transcript
    }

    /// Whether the file's size or modification time differs from the last
    /// read, without opening it.
    public func hasChanged() -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return size != nil }
        return UInt64(info.st_size) != size || Self.modified(info) != modified
    }

    private static func modified(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Read what was appended since the last read. Starts over when the file
    /// was replaced or shrank. Returns false when the file cannot be read.
    @discardableResult
    public mutating func update() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return false }
        let fileSize = UInt64(info.st_size)
        let fileInode = UInt64(info.st_ino)
        let fileModified = Self.modified(info)
        if started, inode != fileInode || fileSize < offset {
            self = LaneTranscript(path: path, window: window)
        }
        inode = fileInode
        size = fileSize
        modified = fileModified
        var skipPartialLine = false
        if !started {
            started = true
            if let window, fileSize > window {
                offset = fileSize - window
                skipPartialLine = true
            }
        }
        guard fileSize > offset else { return true }
        do {
            try handle.seek(toOffset: offset)
            guard var data = try handle.read(upToCount: Int(fileSize - offset)) else { return true }
            offset += UInt64(data.count)
            if skipPartialLine {
                guard let newline = data.firstIndex(of: 0x0A) else { return true }
                data = data[data.index(after: newline)...]
            }
            consume(Data(data))
        } catch {
            return false
        }
        return true
    }

    /// Parse bytes as if appended to the file. A line without its newline
    /// waits for the rest.
    public mutating func consume(_ data: Data) {
        var buffer = remainder
        buffer.append(data)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            if newline > start { parseLine(buffer[start..<newline]) }
            start = buffer.index(after: newline)
        }
        remainder = Data(buffer[start...])
    }

    // MARK: Records

    private mutating func parseLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }
        if let payload = object["payload"] as? [String: Any] {
            parseCodex(type: type, payload: payload)
        } else {
            parseClaude(type: type, object: object)
        }
    }

    private mutating func parseClaude(type: String, object: [String: Any]) {
        if object["isSidechain"] as? Bool == true { return }
        switch type {
        case "user":
            guard let message = object["message"] as? [String: Any] else { return }
            let result = object["toolUseResult"] as? [String: Any]
            if let text = message["content"] as? String {
                userText(text, meta: object["isMeta"] as? Bool == true)
            } else if let blocks = message["content"] as? [[String: Any]] {
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                if results.isEmpty {
                    let text = Self.texts(blocks, type: "text").joined(separator: " ")
                    if !text.isEmpty { userText(text, meta: object["isMeta"] as? Bool == true) }
                } else {
                    for block in results { toolResult(block, result: result) }
                }
            }
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { reply(text) }
                case "tool_use":
                    replyIsLast = false
                    toolUse(block)
                default: break
                }
            }
        case "attachment":
            guard let attachment = object["attachment"] as? [String: Any] else { return }
            switch attachment["type"] as? String {
            case "queued_command":
                if let prompt = attachment["prompt"] as? String { taskNotifications(in: prompt) }
            case "task_status":
                taskStatus(attachment)
            default: break
            }
        case "custom-title":
            if let title = object["customTitle"] as? String { setSessionTitle(title) }
        case "agent-name":
            if let title = object["agentName"] as? String { setSessionTitle(title) }
        case "queue-operation":
            // A notice queued for the agent's next turn arrives here first.
            if object["operation"] as? String == "enqueue", let content = object["content"] as? String {
                taskNotifications(in: content)
            }
        default: break
        }
    }

    private mutating func setSessionTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }

    private mutating func userText(_ text: String, meta: Bool) {
        replyIsLast = false
        if text.contains("<task-notification>") { taskNotifications(in: text) }
        guard !meta else { return }
        prompt(text)
    }

    private mutating func toolUse(_ block: [String: Any]) {
        guard let id = block["id"] as? String, let name = block["name"] as? String else { return }
        let input = block["input"] as? [String: Any] ?? [:]
        switch name {
        case "Bash":
            guard input["run_in_background"] as? Bool == true else { return }
            let description = (input["description"] as? String) ?? (input["command"] as? String).map { String($0.prefix(120)) }
            pendingStarts[id] = .some(description)
        case "TaskStop", "KillShell", "KillBash":
            if let task = (input["task_id"] as? String) ?? (input["shell_id"] as? String) ?? (input["bash_id"] as? String) {
                closeTask(id: task)
            }
        case "BashOutput", "TaskOutput":
            if let task = (input["bash_id"] as? String) ?? (input["task_id"] as? String) ?? (input["shell_id"] as? String) {
                pendingReads[id] = task
            }
        default: break
        }
    }

    private mutating func toolResult(_ block: [String: Any], result: [String: Any]?) {
        guard let useID = block["tool_use_id"] as? String else { return }
        let failed = block["is_error"] as? Bool == true
        if let description = pendingStarts.removeValue(forKey: useID) {
            guard !failed else { return }
            let taskID = (result?["backgroundTaskId"] as? String)
                ?? Self.backgroundID(in: Self.resultText(block))
            if let taskID, !openBackgroundTasks.contains(where: { $0.id == taskID }) {
                openBackgroundTasks.append(BackgroundTask(id: taskID, toolUseID: useID, description: description))
            }
        } else if let task = pendingReads.removeValue(forKey: useID) {
            if let status = result?["status"] as? String, Self.isFinished(status) { closeTask(id: task) }
        }
    }

    private mutating func parseCodex(type: String, payload: [String: Any]) {
        let kind = payload["type"] as? String
        switch (type, kind) {
        case ("event_msg", "user_message"):
            if let text = payload["message"] as? String { replyIsLast = false; prompt(text) }
        case ("event_msg", "agent_message"):
            if let text = payload["message"] as? String { reply(text) }
        case ("event_msg", "task_started"):
            replyIsLast = false
        case ("event_msg", "task_complete"):
            if let text = payload["last_agent_message"] as? String, !text.isEmpty { reply(text) }
        case ("event_msg", "item_completed"):
            guard let item = payload["item"] as? [String: Any],
                  let blocks = item["content"] as? [[String: Any]] else { return }
            switch item["type"] as? String {
            case "UserMessage":
                let text = Self.texts(blocks, type: "text").joined(separator: " ")
                if !text.isEmpty { replyIsLast = false; prompt(text) }
            case "AgentMessage":
                let text = (Self.texts(blocks, type: "Text") + Self.texts(blocks, type: "text")).joined(separator: "\n")
                if !text.isEmpty { reply(text) }
            default: break
            }
        case ("response_item", "message"):
            // The person's messages here also carry injected instructions,
            // so prompts come from the events above.
            guard payload["role"] as? String == "assistant",
                  let blocks = payload["content"] as? [[String: Any]] else { return }
            let text = Self.texts(blocks, type: "output_text").joined(separator: "\n")
            if !text.isEmpty { reply(text) }
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
            replyIsLast = false
        default: break
        }
    }

    // MARK: Facts

    private mutating func prompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Command echoes, notices and other tagged inserts are not typed prompts.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return }
        prompts.append(String(trimmed.prefix(Self.promptLength)))
        if prompts.count > Self.promptLimit { prompts.removeFirst(prompts.count - Self.promptLimit) }
    }

    private mutating func reply(_ text: String) {
        lastReply = text.count > Self.replyLength ? String(text.suffix(Self.replyLength)) : text
        replyIsLast = true
        for link in Self.pullRequestLinks(in: text) where !pullRequestLinks.contains(link) {
            pullRequestLinks.append(link)
        }
        if pullRequestLinks.count > Self.linkLimit { pullRequestLinks.removeFirst(pullRequestLinks.count - Self.linkLimit) }
    }

    /// A snapshot of one background task's state.
    private mutating func taskStatus(_ attachment: [String: Any]) {
        guard attachment["taskType"] as? String == "local_bash", let id = attachment["taskId"] as? String,
              let status = attachment["status"] as? String else { return }
        if Self.isFinished(status) {
            closeTask(id: id)
        } else if !openBackgroundTasks.contains(where: { $0.id == id }) {
            // Started before the part of the file that was read.
            let shell = attachment["shell"] as? [String: Any]
            openBackgroundTasks.append(BackgroundTask(id: id, toolUseID: shell?["toolUseId"] as? String,
                                                      description: attachment["description"] as? String))
        }
    }

    private mutating func closeTask(id: String) {
        openBackgroundTasks.removeAll { $0.id == id }
    }

    private mutating func taskNotifications(in text: String) {
        for notice in Self.notices(in: text) {
            guard let status = notice.status, Self.isFinished(status) else { continue }
            if let id = notice.taskID { closeTask(id: id) }
            if let useID = notice.toolUseID {
                openBackgroundTasks.removeAll { $0.toolUseID == useID }
                pendingStarts.removeValue(forKey: useID)
            }
        }
    }

    /// Statuses that mean a background task is still going; anything else
    /// (`completed`, `failed`, `killed`, `stopped`, …) means it is over.
    static func isFinished(_ status: String) -> Bool {
        !["running", "pending", "started", "in_progress"].contains(status.lowercased())
    }

    static func texts(_ blocks: [[String: Any]], type: String) -> [String] {
        blocks.compactMap { $0["type"] as? String == type ? $0["text"] as? String : nil }
    }

    static func resultText(_ block: [String: Any]) -> String {
        if let text = block["content"] as? String { return text }
        if let blocks = block["content"] as? [[String: Any]] { return texts(blocks, type: "text").joined(separator: "\n") }
        return ""
    }

    /// The task id in a background Bash result's text, for releases whose
    /// result carries no structured id.
    static func backgroundID(in text: String) -> String? {
        guard let range = text.range(of: "running in background with ID: ") else { return nil }
        let id = text[range.upperBound...].prefix { !$0.isWhitespace && $0 != "." && $0 != "," }
        return id.isEmpty ? nil : String(id)
    }

    struct Notice: Equatable {
        var taskID: String?
        var toolUseID: String?
        var status: String?
    }

    /// The `<task-notification>` blocks in a message.
    static func notices(in text: String) -> [Notice] {
        var out: [Notice] = []
        var rest = text[...]
        while let open = rest.range(of: "<task-notification>") {
            let after = rest[open.upperBound...]
            let close = after.range(of: "</task-notification>")
            let body = close.map { after[..<$0.lowerBound] } ?? after
            func tag(_ name: String) -> String? {
                guard let start = body.range(of: "<\(name)>"),
                      let end = body[start.upperBound...].range(of: "</\(name)>") else { return nil }
                let value = body[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            out.append(Notice(taskID: tag("task-id"), toolUseID: tag("tool-use-id"), status: tag("status")))
            guard let close else { break }
            rest = after[close.upperBound...]
        }
        return out
    }

    // MARK: Pull requests

    private static let pullRequestPattern: NSRegularExpression = {
        let label = PullRequestLink.label
        let name = PullRequestLink.name
        let pattern = [
            #"https://github\.com/\#(label)/\#(name)/pull/\d+"#,
            #"https://dev\.azure\.com/\#(label)/\#(name)/_git/\#(name)/pullrequest/\d+"#,
            #"https://\#(label)\.visualstudio\.com/(?:\#(label)/)?\#(name)/_git/\#(name)/pullrequest/\d+"#,
        ].joined(separator: "|")
        // The pattern is a constant, so it always compiles.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// The GitHub and Azure DevOps pull request links in `text`, once each,
    /// keeping only those ``PullRequestLink/isTrusted(_:)`` accepts.
    public static func pullRequestLinks(in text: String) -> [URL] {
        guard text.contains("/pull/") || text.localizedCaseInsensitiveContains("/pullrequest/") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [URL] = []
        for match in pullRequestPattern.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text), let url = URL(string: String(text[r])),
                  PullRequestLink.isTrusted(url), !out.contains(url) else { continue }
            out.append(url)
        }
        return out
    }

    // MARK: Questions

    /// The final sentence of `text` when it is a question, or nil.
    ///
    /// Conservative: code blocks are ignored, then the last line with any
    /// text must end in a question mark (after closing emphasis, brackets or
    /// quotes). A quote, table row, heading, inline code or a link at the end
    /// is not a question.
    public static func finalQuestion(in text: String) -> String? {
        var lines: [Substring] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence { lines.append(line) }
        }
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        var line = last.trimmingCharacters(in: .whitespaces)
        // Indented four spaces is a code block too.
        if last.hasPrefix("    ") || last.hasPrefix("\t") { return nil }
        if line.hasPrefix(">") || line.hasPrefix("|") || line.hasPrefix("#") { return nil }
        let closers: Set<Character> = ["*", "_", ")", "\"", "'", "\u{201D}", "\u{2019}", " "]
        while let end = line.last, closers.contains(end) { line.removeLast() }
        guard let end = line.last, end == "?" || end == "\u{FF1F}" else { return nil }
        if let token = line.split(separator: " ").last, token.contains("://") { return nil }
        // The sentence is what follows the last sentence end before the mark.
        let body = line.dropLast()
        var start = body.startIndex
        var index = body.endIndex
        while index > body.startIndex {
            let previous = body.index(before: index)
            if index < body.endIndex, [".", "!", "?"].contains(body[previous]), body[index] == " " {
                start = index
                break
            }
            index = previous
        }
        var sentence = String(line[start...]).trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where sentence.hasPrefix(marker) { sentence.removeFirst(marker.count) }
        sentence = sentence.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        guard sentence.contains(where: \.isLetter) else { return nil }
        return sentence
    }

    // MARK: Codex

    /// The Codex session file for `threadID`: under `$CODEX_HOME/sessions`
    /// (default `~/.codex/sessions`), in its day folder, named
    /// `rollout-<time>-<thread id>.jsonl`. Newest days are looked at first.
    public static func codexSessionFile(threadID: String,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard !threadID.isEmpty, !threadID.contains("/") else { return nil }
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        let suffix = "-\(threadID).jsonl"
        func children(_ url: URL) -> [URL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { !$0.hasPrefix(".") }.sorted(by: >).map { url.appendingPathComponent($0) }
        }
        func search(_ url: URL, depth: Int) -> URL? {
            for child in children(url) {
                if child.lastPathComponent.hasSuffix(suffix) { return child }
                if depth > 0, child.pathExtension != "jsonl", let found = search(child, depth: depth - 1) { return found }
            }
            return nil
        }
        // sessions/YYYY/MM/DD/rollout-….jsonl, and flat files from old releases.
        return search(root, depth: 3)
    }
}
