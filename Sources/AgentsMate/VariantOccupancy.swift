import Foundation

/// Whether a new lane's session name is already taken, so a new or duplicated
/// lane never attaches a running session or resumes an old conversation.
///
/// A name is taken when a tmux session of exactly that name runs on the lane's
/// host, or a resume ledger holds an entry under it. The check runs through one
/// shell line, here for a lane on this Mac and over `ssh` in batch mode for a
/// lane on another host. A host that cannot be reached counts as taken, since
/// nothing can say the name is free.
///
/// Ledgers are looked for in the folders `AGENTSMATE_LEDGER_DIRS` lists, a
/// colon-separated list in which `~` means the home folder and `*` matches
/// within one name. Without it, `~/.local/state/*-lane/lanes` and
/// `~/.local/state/*-lanes` are searched; a ledger file is named after its
/// session name with every character outside `A-Za-z0-9._-` as `_`.
public struct VariantOccupancy: Sendable {
    /// Runs a program and returns its exit status, or nil when it could not
    /// run or did not finish within the timeout. Replaced in tests.
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> Int32?

    public var ledgerDirectories: [String]
    public var tmuxPath: String
    public var ssh: String
    public var timeout: TimeInterval
    /// This Mac's name in the hosts registry, so a lane that names it runs here.
    public var selfName: String?
    public var run: Runner

    public init(ledgerDirectories: [String]? = nil, tmux: String = "tmux", ssh: String = "/usr/bin/ssh",
                timeout: TimeInterval = 4, selfName: String? = AgentHosts.load()?.selfName,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                run: @escaping Runner = VariantOccupancy.runProcess) {
        let fromEnvironment = environment["AGENTSMATE_LEDGER_DIRS"]?
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        self.ledgerDirectories = ledgerDirectories ?? fromEnvironment
            ?? ["~/.local/state/*-lane/lanes", "~/.local/state/*-lanes"]
        self.tmuxPath = tmux
        self.ssh = ssh
        self.timeout = timeout
        self.selfName = selfName
        self.run = run
    }

    /// The default for ``AgentLaneStore/Configuration/variantOccupied``. Like
    /// shared lanes it only looks outside the process in an app bundle: a test
    /// runner or command-line tool never reads the machine's sessions or ledgers.
    public static let standard = VariantOccupancy()

    /// ``standard``'s answer for the store, or false outside an app bundle.
    public static func standardIsOccupied(backendID: String, sessionName: String, host: String?) -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return false }
        return standard.isOccupied(backendID: backendID, sessionName: sessionName, host: host)
    }

    public func isOccupied(backendID: String, sessionName: String, host: String?) -> Bool {
        guard TmuxLaneSessions.isValidSessionName(sessionName) else { return true }
        let script = shellLine(sessionName: sessionName)
        if let host, host != selfName {
            guard TmuxLaneSessions(host: host).validHost != nil else { return true }
            guard let status = run(ssh, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--", host, script], timeout) else { return true }
            // 0 holds the name, 1 does not; ssh's own failure (255) or anything else is unknown.
            return status != 1
        }
        guard let status = run("/bin/sh", ["-c", script], timeout) else { return true }
        return status != 1
    }

    /// Exits 0 when the name is held, 1 when it is free.
    func shellLine(sessionName: String) -> String {
        let file = String(sessionName.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "_"
        })
        let dirs = ledgerDirectories.map { dir -> String in
            let expanded = dir.hasPrefix("~") ? "$HOME" + dir.dropFirst() : dir
            return "\"" + expanded.replacingOccurrences(of: "\"", with: "") + "\"/" + ShellQuote.quote(file)
        }.joined(separator: " ")
        let target = ShellQuote.quote("=" + sessionName)
        let tmux = ShellQuote.quote(tmuxPath)
        return "for f in \(dirs); do [ -e \"$f\" ] && exit 0; done; "
            + "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; command -v \(tmux) >/dev/null 2>&1 || exit 1; "
            + "\(tmux) has-session -t \(target) >/dev/null 2>&1 && exit 0; exit 1"
    }

    public static let runProcess: Runner = { executable, arguments, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }
}
