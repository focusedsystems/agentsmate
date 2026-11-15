import Foundation

/// Where the `claude` command-line tool is installed.
public enum ClaudeBinary {
    /// A GUI app does not inherit the person's shell PATH, so the usual
    /// install locations are checked first, then a login shell is asked.
    public static func locate() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return loginShellLookup()
    }

    private static func loginShellLookup() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
