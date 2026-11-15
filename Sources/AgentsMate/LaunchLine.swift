import Foundation

/// Hands an agent an app's instructions and extra folders on its command
/// line, for the agents that take them: Claude Code reads a prompt file
/// (`--append-system-prompt-file`) and Codex a developer-instructions value
/// (`-c developer_instructions=…`). Other commands, and agent subcommands that
/// do not start a session, are left as they are.
public enum LaunchLine {
    static let claudeNonSession: Set<String> = [
        "mcp", "config", "doctor", "update", "install", "migrate-installer", "setup-token", "plugin",
        "agents", "attach", "logs", "stop", "rm", "auth", "login", "logout",
    ]
    static let codexNonSession: Set<String> = [
        "exec", "login", "logout", "mcp", "mcp-server", "app-server", "completion", "update", "doctor",
        "debug", "features", "help", "apply", "cloud", "sandbox", "proto",
    ]
    static let informational: Set<String> = ["--help", "-h", "--version", "-V", "-v"]

    /// `command` with `promptFile` and `directories` added where the agent
    /// takes them.
    public static func inject(_ command: String, promptFile: URL?, directories: [String] = []) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let program = words.first else { return command }
        let rest = Array(words.dropFirst())
        if rest.contains(where: informational.contains) { return command }
        let tail = rest.isEmpty ? "" : " " + rest.joined(separator: " ")
        var seen = Set<String>()
        let dirs = directories.filter { !$0.isEmpty && seen.insert($0).inserted }
        switch (program as NSString).lastPathComponent {
        case "claude":
            if let next = rest.first, claudeNonSession.contains(next) { return command }
            var line = program
            if let promptFile { line += " --append-system-prompt-file " + ShellQuote.quote(promptFile.path) }
            line += dirs.map { " --add-dir " + ShellQuote.quote($0) }.joined()
            return line + tail
        case "codex":
            if let next = rest.first, codexNonSession.contains(next) { return command }
            var line = program
            if let promptFile {
                line += " -c \"developer_instructions=$(cat " + ShellQuote.quote(promptFile.path) + ")\""
            }
            // Codex refuses extra folders unless the workspace is writable.
            if Self.codexSandbox(rest) == "workspace-write" {
                line += dirs.map { " --add-dir " + ShellQuote.quote($0) }.joined()
            }
            return line + tail
        default:
            return command
        }
    }

    static func codexSandbox(_ words: [String]) -> String? {
        for (i, w) in words.enumerated() {
            if (w == "--sandbox" || w == "-s"), i + 1 < words.count { return words[i + 1] }
            if w.hasPrefix("--sandbox=") { return String(w.dropFirst("--sandbox=".count)) }
        }
        return nil
    }

    /// Whether `command`'s program is installed in a folder a login shell
    /// puts on PATH. An app started by launchd has a bare PATH, so the
    /// folders are checked directly. An empty command (the shell) always is.
    public static func isInstalled(_ command: String, home: String = NSHomeDirectory()) -> Bool {
        guard let program = command.split(separator: " ").first.map(String.init) else { return true }
        if program.contains("/") { return FileManager.default.isExecutableFile(atPath: (program as NSString).expandingTildeInPath) }
        let folders = ["\(home)/.local/bin", "\(home)/bin", "\(home)/.npm-global/bin", "\(home)/.claude/local",
                       "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return folders.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + program) }
    }
}
