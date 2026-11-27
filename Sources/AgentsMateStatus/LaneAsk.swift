import Foundation

/// Ask a question about past agent work, such as "which lane was I working on
/// the login bug in?", and get lanes back.
///
/// The search itself is a command the person installs. AgentsMate runs it with
/// `--json` and the question, reads one JSON object from its output (see
/// `docs/ask.md`), and never searches anything itself, so the command decides
/// which Macs, transcripts and lane lists it looks through. The command's
/// name defaults to ``defaultCommand`` and is looked up on `PATH` plus the
/// usual per-user bin folders, since an app started from the Dock has a short
/// `PATH`.
///
/// The command is the only child process: AgentsMate starts it, waits for its
/// output, and ends it when the answer arrives, when the person cancels, or
/// when ``defaultTimeout`` passes. Nothing is left running.
public enum LaneAsk {
    public static let defaultCommand = "lane-find"
    public static let defaultTimeout: TimeInterval = 150

    /// One lane or session the command thinks the question is about.
    public struct Answer: Equatable, Sendable, Identifiable {
        public var rank: Int
        /// The Mac the session is on, by the name the command uses.
        public var host: String
        /// `claude`, `codex`, or whatever else the command reports.
        public var agent: String
        /// The lane's id in its app, when the command could tie the session to one.
        public var laneID: String?
        /// The bundle id of the app that lists the lane.
        public var app: String?
        public var sessionID: String?
        public var folder: String?
        public var lastActive: Date?
        public var title: String?
        public var evidence: String
        public var why: String
        public var workItems: [String]

        public var id: String { "\(host)/\(laneID ?? sessionID ?? String(rank))" }
    }

    /// What the command printed.
    public struct Response: Equatable, Sendable {
        public var question: String
        /// Whether a model read the best candidates, or keywords alone ranked them.
        public var usedModel: Bool
        public var hostsSkipped: [String]
        public var answers: [Answer]
    }

    public enum Outcome: Equatable, Sendable {
        case answers(Response)
        /// The command ran and found nothing.
        case noMatch(Response)
        /// No executable with that name was found; the associated value is the name.
        case missingCommand(String)
        case failed(String)
        case cancelled
    }

    // MARK: Parsing

    private struct Wire: Decodable {
        struct Row: Decodable {
            var rank: Int?
            var host: String?
            var agent: String?
            var laneID: String?
            var app: String?
            var sessionID: String?
            var cwd: String?
            var lastActive: String?
            var title: String?
            var evidence: String?
            var why: String?
            var workItems: [String]?

            enum CodingKeys: String, CodingKey {
                case rank, host, agent, app, cwd, title, evidence, why
                case laneID = "lane_id", sessionID = "session_id", lastActive = "last_active", workItems = "work_items"
            }
        }

        var question: String?
        var llm: Bool?
        var hostsSkipped: [String]?
        var results: [Row]?

        enum CodingKeys: String, CodingKey {
            case question, llm, results
            case hostsSkipped = "hosts_skipped"
        }
    }

    /// The response in `data`, or nil when it is not the command's JSON.
    public static func parse(_ data: Data) -> Response? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        let answers = (wire.results ?? []).enumerated().compactMap { index, row -> Answer? in
            guard let host = row.host, !host.isEmpty else { return nil }
            return Answer(rank: row.rank ?? index + 1, host: host, agent: row.agent ?? "agent",
                          laneID: nonEmpty(row.laneID), app: nonEmpty(row.app), sessionID: nonEmpty(row.sessionID),
                          folder: nonEmpty(row.cwd), lastActive: row.lastActive.flatMap(date(from:)),
                          title: nonEmpty(row.title), evidence: row.evidence ?? "", why: row.why ?? "",
                          workItems: row.workItems ?? [])
        }
        return Response(question: wire.question ?? "", usedModel: wire.llm ?? false,
                        hostsSkipped: wire.hostsSkipped ?? [], answers: answers)
    }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    private static func date(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    // MARK: Finding and running the command

    /// A command name is a bare file name, never a path, so a setting cannot point at a script elsewhere.
    public static func isValidCommandName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix("-") && !name.hasPrefix(".")
            && name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    /// The folders searched for the command: `PATH`, then the per-user and Homebrew bin folders.
    public static func searchFolders(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let given = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        return (given + extra).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func locate(_ command: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard isValidCommandName(command) else { return nil }
        for folder in searchFolders(environment: environment) {
            let path = (folder as NSString).appendingPathComponent(command)
            var isDirectory: ObjCBool = false
            if FileManager.default.isExecutableFile(atPath: path),
               FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Run the command for `question` and wait for its answer. Cancelling the
    /// calling task ends the command.
    public static func run(question: String, command: String = defaultCommand, timeout: TimeInterval = defaultTimeout,
                           environment: [String: String] = ProcessInfo.processInfo.environment) async -> Outcome {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed("Type a question first.") }
        guard let executable = locate(command, environment: environment) else { return .missingCommand(command) }
        var childEnvironment = environment
        childEnvironment["PATH"] = searchFolders(environment: environment).joined(separator: ":")
        let child = Child()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: child.run(executable: executable, question: text,
                                                             environment: childEnvironment, timeout: timeout))
                }
            }
        } onCancel: {
            child.cancel()
        }
    }

    /// The one running command, which can be ended from another thread.
    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            end(running)
        }

        /// Ask the command to stop, which it passes on to what it started; kill it if it will not.
        private func end(_ process: Process?) {
            guard let process, process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        func run(executable: URL, question: String, environment: [String: String], timeout: TimeInterval) -> Outcome {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--json", "--", question]
            process.environment = environment
            process.qualityOfService = .userInitiated
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err

            lock.lock()
            if cancelled { lock.unlock(); return .cancelled }
            do { try process.run() } catch {
                lock.unlock()
                return .failed("Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
            }
            self.process = process
            lock.unlock()

            let timedOut = Flag()
            let limit = DispatchWorkItem { [weak self] in
                timedOut.set()
                self?.end(process)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: limit)

            let errorReader = Collector()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errorReader.data = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            group.wait()
            limit.cancel()

            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { return .cancelled }
            if timedOut.isSet { return .failed("The search took longer than \(Int(timeout)) seconds and was stopped.") }

            let response = data.count <= 4_000_000 ? parse(data) : nil
            switch process.terminationStatus {
            case 0:
                guard let response else { return .failed("The search printed something that is not an answer.") }
                return response.answers.isEmpty ? .noMatch(response) : .answers(response)
            case 1:
                let empty = Response(question: question, usedModel: false, hostsSkipped: [], answers: [])
                return .noMatch(response ?? empty)
            default:
                let message = String(decoding: errorReader.data.suffix(400), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed(message.isEmpty ? "The search stopped with status \(process.terminationStatus)." : message)
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Collector: @unchecked Sendable {
        var data = Data()
    }

    // MARK: Opening an answer

    /// Whether `id` can be an agent session id: letters, digits, dots, dashes and underscores.
    public static func isValidSessionID(_ id: String) -> Bool {
        (8...80).contains(id.count) && id.first?.isASCII == true && id.first.map { $0.isLetter || $0.isNumber } == true
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The board card that already shows this answer's session or lane, when
    /// one does, so opening the answer selects it rather than starting another.
    public static func card(for answer: Answer, in cards: [AgentBoard.Card]) -> AgentBoard.Card? {
        func sameHost(_ card: AgentBoard.Card) -> Bool { card.host.caseInsensitiveCompare(answer.host) == .orderedSame }
        if let lane = answer.laneID,
           let hit = cards.first(where: { $0.laneID == lane && (answer.app == nil || $0.app == nil || $0.app == answer.app) }) {
            return hit
        }
        guard let session = answer.sessionID?.lowercased() else { return nil }
        return cards.first { card in
            sameHost(card) && [card.conversationID, card.sessionID].contains { $0?.lowercased() == session }
        }
    }

    /// The shell line that resumes the answer's conversation in its folder, on
    /// its own Mac, for a session no app shows. Nil when the answer lacks a
    /// valid session id, folder or host, so nothing unchecked reaches a shell.
    public static func resumeCommand(for answer: Answer, isLocal: Bool) -> String? {
        guard let session = answer.sessionID, isValidSessionID(session) else { return nil }
        let resume: String
        switch answer.agent {
        case "claude": resume = "claude --resume " + ShellWords.quote(session)
        case "codex": resume = "codex resume " + ShellWords.quote(session)
        default: return nil
        }
        var line = resume
        if let folder = answer.folder {
            guard folder.hasPrefix("/"), !folder.contains(where: \.isNewline), !folder.contains("\0") else { return nil }
            line = "cd " + ShellWords.quote(folder) + " && " + resume
        }
        let shell = "/bin/zsh -lc " + ShellWords.quote("exec " + line)
        if isLocal { return "exec " + shell }
        guard AgentSessionStop.isValidHost(answer.host) else { return nil }
        return "exec /usr/bin/ssh -t -- " + ShellWords.quote(answer.host) + " " + ShellWords.quote(shell)
    }
}
