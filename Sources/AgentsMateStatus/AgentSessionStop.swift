import Foundation

/// Ending an agent's session for good, on this Mac or another, and knowing
/// whether it ended.
///
/// - A Claude Code background session: `claude stop <id>` on the Mac it
///   runs on, then its list is read until the id is gone. Its conversation
///   is kept.
/// - A tmux lane: when Claude Code or Codex is in front in its pane, `/exit`
///   is typed so the agent ends its turn and saves; the session is ended
///   with `kill-session` once the agent has gone, or after a few seconds.
///
/// Callers confirm with the person first. Every command is read-only except
/// the stop itself, and nothing is matched by part of a name.
public enum AgentSessionStop {
    public enum Target: Equatable, Sendable {
        case claudeBackground(id: String)
        case tmux(name: String)
    }

    public struct Outcome: Equatable, Sendable {
        public var stopped: Bool
        public var message: String?
    }

    /// A Claude short id: letters, digits and dashes, not starting with a dash.
    public static func isValidClaudeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix("-")
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A tmux session name that is safe to hand to tmux as `=name`.
    public static func isValidTmuxName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && !name.hasPrefix("-")
            && !name.contains(where: { $0 == ":" || $0 == "." || $0 == "'" || $0.isNewline })
    }

    /// The script that stops `target` and exits 0 only once it has ended.
    public static func script(for target: Target, claude: String = "claude", tmux: String = "tmux",
                              wait: Int = 10) -> String? {
        let q = ShellWords.quote
        switch target {
        case .claudeBackground(let id):
            guard isValidClaudeID(id) else { return nil }
            let c: String = q(claude)
            let needle: String = q("\"id\":\"\(id)\"")
            let failed: String = q("Claude still lists \(id) as running.")
            // The default list leaves stopped sessions out.
            let lines: [String] = [
                "\(c) stop \(q(id)) >/dev/null 2>&1",
                "i=0",
                "while [ $i -lt \(wait) ]; do",
                "  \(c) agents --json 2>/dev/null | tr -d ' \\n' | grep -q \(needle) || exit 0",
                "  sleep 1; i=$((i+1))",
                "done",
                "echo \(failed)",
                "exit 1",
            ]
            return lines.joined(separator: "\n")
        case .tmux(let name):
            guard isValidTmuxName(name) else { return nil }
            let t: String = q(tmux)
            let session: String = q("=" + name)
            let pane: String = q("=" + name + ":")
            let failed: String = q("tmux still has \(name).")
            let lines: [String] = [
                "\(t) has-session -t \(session) 2>/dev/null || exit 0",
                "c=$(\(t) display-message -p -t \(pane) '#{pane_current_command}' 2>/dev/null)",
                "case \"$c\" in claude|codex|node)",
                "  \(t) send-keys -t \(pane) C-u",
                "  \(t) send-keys -t \(pane) -l /exit",
                "  \(t) send-keys -t \(pane) Enter",
                "  i=0",
                "  while [ $i -lt \(wait * 2) ]; do",
                "    n=$(\(t) display-message -p -t \(pane) '#{pane_current_command}' 2>/dev/null) || break",
                "    [ \"$n\" = \"$c\" ] || break",
                "    sleep 0.5; i=$((i+1))",
                "  done ;;",
                "esac",
                "\(t) kill-session -t \(session) 2>/dev/null",
                "if \(t) has-session -t \(session) 2>/dev/null; then echo \(failed); exit 1; fi",
                "exit 0",
            ]
            return lines.joined(separator: "\n")
        }
    }

    /// The process that runs `script`: in a login shell here when `host` is
    /// nil, else the same over `ssh` in batch mode.
    public static func command(script: String, host: String?, shell: String = "/bin/zsh",
                               ssh: String = "/usr/bin/ssh", connectTimeout: Int = 5) -> (executable: String, arguments: [String])? {
        guard let host else { return (shell, ["-lc", script]) }
        guard isValidHost(host) else { return nil }
        let remote = ShellWords.quote(shell) + " -lc " + ShellWords.quote(script)
        return (ssh, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "-T", "--", host, remote])
    }

    /// An ssh host alias: no leading dash, no spaces or shell characters.
    public static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 255 && !host.hasPrefix("-")
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }
    }

    /// Stop `target` on `host` (nil for this Mac) and report whether it ended.
    public static func run(_ target: Target, host: String?, claude: String = "claude", tmux: String = "tmux",
                           timeout: TimeInterval = 40) async -> Outcome {
        guard let script = script(for: target, claude: claude, tmux: tmux),
              let command = command(script: script, host: host) else {
            return Outcome(stopped: false, message: "That session cannot be named safely, so it was not stopped.")
        }
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch {
                return Outcome(stopped: false, message: "Could not run the stop: \(error.localizedDescription)")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0 { return Outcome(stopped: true, message: nil) }
            if host != nil, process.terminationStatus == 255 {
                return Outcome(stopped: false, message: "\(host!) did not answer over ssh.")
            }
            return Outcome(stopped: false, message: text.isEmpty ? "The session did not stop." : text)
        }.value
    }
}
