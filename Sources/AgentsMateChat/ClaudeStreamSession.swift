import Foundation

/// A long-lived `claude -p --input-format stream-json --output-format stream-json`
/// subprocess, bridged to an ``AsyncThrowingStream`` of ``ClaudeStreamEvent``.
///
/// Isolation: this actor owns the `Process` and its pipes (all non-`Sendable`),
/// so every touch of them stays inside the actor. `events()` is `nonisolated`
/// only to hand back the stream synchronously; the work it kicks off hops onto
/// the actor. The output stream has a single consumer (the caller).
///
/// Reading uses `readabilityHandler` → an ordered `AsyncStream<Data>` rather
/// than `FileHandle.bytes`, which can fail to wake on new pipe data.
public actor ClaudeStreamSession {
    private let binary: URL
    private let workingDirectory: URL?
    private let permissionMode: String
    private let model: String?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var continuation: AsyncThrowingStream<ClaudeStreamEvent, Error>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var started = false
    private var sawResult = false
    private var stderrBuffer = ""

    /// `permissionMode` is a Claude Code `--permission-mode` value, such as
    /// `plan`, `acceptEdits` or `bypassPermissions`. Nil `model` is Claude's default.
    public init(binary: URL, workingDirectory: URL?, permissionMode: String, model: String? = nil) {
        self.binary = binary
        self.workingDirectory = workingDirectory
        self.permissionMode = permissionMode
        self.model = model
    }

    public nonisolated func events() -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { await self.start(continuation: continuation) }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.stop() }
            }
        }
    }

    public func send(_ text: String) async throws {
        guard started else { throw ClaudeStreamError.notStarted }
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func stop() async {
        readerTask?.cancel()
        stderrTask?.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Launch

    private func start(continuation: AsyncThrowingStream<ClaudeStreamEvent, Error>.Continuation) {
        guard !started else { return }
        started = true
        self.continuation = continuation

        process.executableURL = binary
        process.arguments = arguments()
        process.currentDirectoryURL = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        process.environment = childEnvironment()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            continuation.yield(.providerError(error.localizedDescription))
            continuation.finish()
            return
        }

        let outStream = Self.dataStream(from: stdoutPipe.fileHandleForReading)
        let errStream = Self.dataStream(from: stderrPipe.fileHandleForReading)
        readerTask = Task { await self.consumeStdout(outStream, into: continuation) }
        stderrTask = Task { await self.consumeStderr(errStream) }
    }

    private func arguments() -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", permissionMode,
        ]
        if let model { args += ["--model", model] }
        return args
    }

    /// GUI apps inherit a sparse `PATH`; `claude` may shell out to `node`, the
    /// project tools, etc. Make sure the usual locations are present.
    private func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        return env
    }

    // MARK: - Reading

    /// Bridge a pipe's read end to an ordered byte stream. The readability
    /// handler fires on a private serial queue, so chunks arrive in order; an
    /// empty chunk signals EOF.
    private nonisolated static func dataStream(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                continuation.yield(chunk)
                if chunk.isEmpty {
                    fileHandle.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }
    }

    private func consumeStdout(_ stream: AsyncStream<Data>, into continuation: AsyncThrowingStream<ClaudeStreamEvent, Error>.Continuation) async {
        var buffer = Data()
        for await chunk in stream {
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                for event in ClaudeStreamParser.parse(line: line) {
                    if case .turnComplete = event { sawResult = true }
                    continuation.yield(event)
                }
            }
        }
        finishAfterRead()
    }

    private func consumeStderr(_ stream: AsyncStream<Data>) async {
        for await chunk in stream {
            if chunk.isEmpty { break }
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            stderrBuffer += text
            if stderrBuffer.count > 4000 { stderrBuffer = String(stderrBuffer.suffix(4000)) }
        }
    }

    private func finishAfterRead() {
        guard let continuation else { return }
        let status: Int32 = process.isRunning ? 0 : process.terminationStatus
        if status != 0 && !sawResult {
            let tail = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.yield(.providerError(tail.isEmpty ? "claude exited with status \(status)" : tail))
        }
        continuation.finish()
        self.continuation = nil
    }
}

/// Stateless decoder from one NDJSON line of Claude Code's `stream-json` output
/// to zero or more ``ClaudeStreamEvent``s.
///
/// Text is taken only from `stream_event` deltas; the consolidated `assistant`
/// message is mined only for `tool_use` blocks, so text isn't double-counted.
public enum ClaudeStreamParser {
    public static func parse(line: String) -> [ClaudeStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return []
        }

        switch type {
        case "system":
            guard obj["subtype"] as? String == "init" else { return [] }
            let sessionID = obj["session_id"] as? String ?? ""
            return [.sessionStarted(sessionID: sessionID, cwd: obj["cwd"] as? String)]

        case "stream_event":
            return parseStreamEvent(obj["event"] as? [String: Any])

        case "assistant":
            return toolUses(in: obj["message"] as? [String: Any])

        case "user":
            return toolResults(in: obj["message"] as? [String: Any])

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? (obj["subtype"] as? String != "success")
            return [.turnComplete(isError: isError)]

        default:
            return []
        }
    }

    private static func parseStreamEvent(_ event: [String: Any]?) -> [ClaudeStreamEvent] {
        guard let event, event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String else {
            return []
        }
        return [.textDelta(text)]
    }

    private static func toolUses(in message: [String: Any]?) -> [ClaudeStreamEvent] {
        guard let blocks = message?["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "tool_use",
                  let name = block["name"] as? String else { return nil }
            return .toolUse(name: name, summary: summarize(input: block["input"]))
        }
    }

    private static func toolResults(in message: [String: Any]?) -> [ClaudeStreamEvent] {
        guard let blocks = message?["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "tool_result" else { return nil }
            let isError = block["is_error"] as? Bool ?? false
            return .toolResult(summary: stringify(block["content"]), isError: isError)
        }
    }

    /// Pick the most telling field of a tool input for a one-line preview.
    private static func summarize(input: Any?) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        for key in ["command", "file_path", "path", "pattern", "query", "description", "prompt"] {
            if let value = dict[key] as? String { return truncate(value, 120) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            return truncate(json, 120)
        }
        return ""
    }

    private static func stringify(_ content: Any?) -> String {
        if let text = content as? String { return truncate(text, 200) }
        if let blocks = content as? [[String: Any]] {
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
            return truncate(text, 200)
        }
        return ""
    }

    private static func truncate(_ string: String, _ limit: Int) -> String {
        let collapsed = string.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }
}
