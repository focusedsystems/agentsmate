import Foundation
import SwiftTerm

/// Renames a Claude background session without a lane's terminal: it
/// attaches the session in a pseudo-terminal of its own, types the rename
/// command, waits for Claude to say it renamed, and lets go. The session
/// keeps running whether anything is attached, and Claude runs a rename
/// while a turn is under way, so this reaches rows that are not open here,
/// rows whose agent is busy, and sessions on another Mac (the attach then
/// runs over `ssh`).
final class HeadlessAgentRename: LocalProcessDelegate, @unchecked Sendable {
    /// How long to wait for the session's prompt to draw, and then for Claude
    /// to confirm the new name.
    struct Timing: Sendable {
        var ready: TimeInterval = 8
        var confirm: TimeInterval = 10
        var gap: TimeInterval = LaneRename.returnDelay
    }

    private let queue = DispatchQueue(label: "agentsmate.headless-rename")
    private var process: LocalProcess?
    private var output = ""
    private var stage = Stage.starting
    private var continuation: CheckedContinuation<Bool, Never>?

    private enum Stage { case starting, typed, done }

    /// What Claude's screen shows once a session is attached and takes
    /// input, and once a rename has gone through.
    static let confirmation = "Session renamed to"
    static let settle: TimeInterval = 0.5

    /// Screen output as plain words: cursor movements, which Claude puts
    /// between the words of a line, become spaces and escapes are dropped.
    static func plain(_ output: String) -> String {
        let stripped = output
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?<>=]*[ -/]*[@-~]", with: " ", options: .regularExpression)
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Run `launch` in a pseudo-terminal and type `command` into it. True
    /// when Claude confirmed the rename.
    static func run(_ launch: TerminalLaunch, command: String, environment: [String: String],
                    timing: Timing = Timing()) async -> Bool {
        let job = HeadlessAgentRename()
        return await job.start(launch, command: command, environment: environment, timing: timing)
    }

    private func start(_ launch: TerminalLaunch, command: String, environment: [String: String],
                       timing: Timing) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async {
                self.continuation = continuation
                self.command = command
                self.gap = timing.gap
                let process = LocalProcess(delegate: self, dispatchQueue: self.queue)
                self.process = process
                var env = environment
                env["TERM"] = "xterm-256color"
                process.startProcess(executable: launch.executable, args: launch.arguments,
                                     environment: env.map { "\($0.key)=\($0.value)" }, execName: nil,
                                     currentDirectory: launch.directory)
                self.queue.asyncAfter(deadline: .now() + timing.ready) { [weak self] in
                    guard let self, self.stage == .starting else { return }
                    // The prompt never showed: an unreadable screen is not typed into.
                    self.finish(false)
                }
                self.queue.asyncAfter(deadline: .now() + timing.ready + timing.confirm + timing.gap) { [weak self] in
                    self?.finish(false)
                }
            }
        }
    }

    private var command = ""
    private var gap: TimeInterval = 0

    private func finish(_ renamed: Bool) {
        guard continuation != nil else { return }
        stage = .done
        process?.terminate()
        process = nil
        continuation?.resume(returning: renamed)
        continuation = nil
    }

    // MARK: LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        queue.async { self.finish(false) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        screen.feed(buffer: slice)
        output += String(decoding: slice, as: UTF8.self)
        if output.count > 200_000 { output = String(output.suffix(100_000)) }
        switch stage {
        case .starting:
            if Self.refusal(onScreen: screen) { return finish(false) }
            generation += 1
            let seen = generation
            // Judge the screen once it has stopped drawing.
            queue.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
                guard let self, self.stage == .starting, self.generation == seen else { return }
                if Self.refusal(onScreen: self.screen) { return self.finish(false) }
                // Only a real, empty input line is typed into.
                guard AgentPromptLine.read(self.screen) == .empty else { return }
                self.stage = .typed
                self.output = ""
                self.process?.send(data: ArraySlice(Array(self.command.utf8)))
                self.queue.asyncAfter(deadline: .now() + self.gap) { [weak self] in
                    guard let self, self.stage == .typed else { return }
                    // Return is sent only to a line that holds exactly what was typed.
                    guard !Self.refusal(onScreen: self.screen), Self.typedLine(on: self.screen) == self.command else {
                        self.process?.send(data: ArraySlice([0x15]))
                        return self.finish(false)
                    }
                    self.process?.send(data: ArraySlice([0x0D]))
                }
            }
        case .typed:
            if Self.plain(output).contains(Self.confirmation) { finish(true) }
        case .done:
            break
        }
    }

    // MARK: Screen

    private let screen = Terminal(delegate: ScreenDelegate(), options: TerminalOptions(cols: 120, rows: 40))
    private var generation = 0

    private final class ScreenDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// The screen's rows as text.
    static func rows(of terminal: Terminal) -> [String] {
        (0..<terminal.rows).map { y in
            guard let line = terminal.getLine(row: y) else { return "" }
            return String((0..<min(line.count, terminal.cols)).map { terminal.getCharacter(for: line[$0]) })
                .map { $0 == "\0" || $0 == "\u{00A0}" ? " " : $0 }.reduce(into: "") { $0.append($1) }
        }
    }

    /// Whether a question, a trust prompt or a numbered menu is showing, so
    /// that Return would answer it rather than run a command.
    static func refusal(onScreen terminal: Terminal) -> Bool {
        refusal(in: rows(of: terminal))
    }

    static func refusal(in rows: [String]) -> Bool {
        for row in rows {
            let text = row.lowercased()
            if text.contains("do you want") || text.contains("trust this") || text.contains("trust the files")
                || text.contains("(y/n)") || text.contains("[y/n]") { return true }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let unmarked = trimmed.drop(while: { "❯>›│ ".contains($0) })
            if let dot = unmarked.firstIndex(of: "."), unmarked.startIndex != dot,
               unmarked[..<dot].allSatisfy(\.isNumber), unmarked[unmarked.index(after: dot)...].first == " " { return true }
        }
        return false
    }

    /// What follows the marker on the input line under the cursor.
    static func typedLine(on terminal: Terminal) -> String? {
        let rows = rows(of: terminal)
        let y = terminal.getCursorLocation().y
        guard rows.indices.contains(y), let marker = rows[y].firstIndex(where: { AgentPromptLine.markers.contains($0) }) else { return nil }
        return rows[y][rows[y].index(after: marker)...].trimmingCharacters(in: .whitespaces)
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
    }
}
