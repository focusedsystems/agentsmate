import Foundation
import Darwin

/// What a lane's row can show about the work in it: the git branch of its
/// folder, the pull request for that branch, and the TCP ports its programs
/// listen on.
public struct LaneRowMetadata: Equatable, Sendable {
    public struct PullRequest: Equatable, Sendable {
        public enum State: String, Codable, Sendable { case open, draft, merged, closed }
        public var number: Int
        public var state: State
        public var url: URL?
    }

    public var branch: String?
    public var pullRequest: PullRequest?
    public var ports: [Int] = []

    public init(branch: String? = nil, pullRequest: PullRequest? = nil, ports: [Int] = []) {
        self.branch = branch
        self.pullRequest = pullRequest
        self.ports = ports
    }
}

/// Reads row metadata without blocking the main thread: the branch from the
/// repository's HEAD file, ports from `lsof` over the lane's process tree,
/// and the pull request from `gh`, cached for five minutes per branch.
public enum LaneRowMetadataReader {
    /// The branch checked out in the repository that holds `directory`, or a
    /// short commit for a detached HEAD. Nil outside a repository.
    public static func branch(in directory: String) -> String? {
        headFile(for: directory).flatMap(branch(headFile:))
    }

    /// The branch a HEAD file names.
    public static func branch(headFile: URL) -> String? {
        parseHead(try? String(contentsOf: headFile, encoding: .utf8))
    }

    /// The HEAD file of the repository that holds `directory`, following a
    /// worktree's or submodule's `.git` file to its real git folder. Nil
    /// outside a repository.
    public static func headFile(for directory: String) -> URL? {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        let fm = FileManager.default
        while true {
            let dotGit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue { return dotGit.appendingPathComponent("HEAD") }
                // A worktree or submodule: ".git" names the real folder.
                return gitDir(fromDotGitFile: try? String(contentsOf: dotGit, encoding: .utf8), in: url)?
                    .appendingPathComponent("HEAD")
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// The GitHub repository (`owner/repo`) the `origin` remote of the
    /// repository holding `directory` points at, read from its git config.
    /// A worktree's config is its main repository's. Nil outside a
    /// repository, with no origin, or for another host.
    public static func originRepository(in directory: String) -> String? {
        guard let gitDir = headFile(for: directory)?.deletingLastPathComponent() else { return nil }
        var common = gitDir
        if let text = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                common = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: gitDir.path, isDirectory: true))
                    .standardizedFileURL
            }
        }
        let config = try? String(contentsOf: common.appendingPathComponent("config"), encoding: .utf8)
        return originURL(inConfig: config).flatMap(gitHubRepository(fromRemote:))
    }

    /// The `url` of `[remote "origin"]` in a git config file.
    static func originURL(inConfig text: String?) -> String? {
        guard let text else { return nil }
        var inOrigin = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == #"[remote"origin"]"#
                continue
            }
            guard inOrigin, line.hasPrefix("url") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `owner/repo` from a github.com remote: `git@github.com:owner/repo.git`,
    /// `https://github.com/owner/repo` or `ssh://git@github.com/owner/repo`.
    static func gitHubRepository(fromRemote remote: String) -> String? {
        var path: Substring
        if let range = remote.range(of: "github.com:"), !remote.contains("://") {
            path = remote[range.upperBound...]
        } else if let url = URL(string: remote), url.host(percentEncoded: true)?.lowercased() == "github.com" {
            path = Substring(url.path(percentEncoded: false))
        } else {
            return nil
        }
        while path.hasPrefix("/") { path = path.dropFirst() }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return parts.joined(separator: "/")
    }

    /// The folder a `.git` file's `gitdir:` line names, resolved against the
    /// folder holding the file when it is relative.
    static func gitDir(fromDotGitFile text: String?, in folder: URL) -> URL? {
        guard let text,
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        // Relative to the folder itself, not to its parent.
        let base = URL(fileURLWithPath: folder.path, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    static func parseHead(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("ref: ") {
            let ref = text.hasPrefix("ref: refs/heads/") ? String(text.dropFirst("ref: refs/heads/".count))
                                                          : String(text.dropFirst("ref: ".count))
            return isSafeRefName(ref) ? ref : nil
        }
        let commit = String(text.prefix(7))
        return commit.allSatisfy(\.isHexDigit) ? commit : nil
    }

    /// A branch name that can be passed as an argument: git's ref-name rules
    /// in short, and never one that would read as an option.
    static func isSafeRefName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("@{"), !name.contains("//") else { return false }
        let banned = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
        return name.unicodeScalars.allSatisfy { !banned.contains($0) }
    }

    /// `pid` and every process below it.
    public static func processTree(_ pid: pid_t) -> [pid_t] {
        var out: [pid_t] = [pid]
        var queue = [pid]
        while let next = queue.popLast() {
            let count = proc_listchildpids(next, nil, 0)
            guard count > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(count) * 2)
            let filled = proc_listchildpids(next, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            for child in children.prefix(Int(max(filled, 0))) where child > 0 && !out.contains(child) {
                out.append(child)
                queue.append(child)
            }
        }
        return out
    }

    /// TCP ports any of `pids` listen on, from `lsof`.
    public static func listeningPorts(pids: [pid_t]) -> [Int] {
        guard !pids.isEmpty else { return [] }
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pids.map(String.init).joined(separator: ","), "-Fn"])
        return parsePorts(output)
    }

    static func parsePorts(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            if let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) { ports.insert(port) }
        }
        return ports.sorted()
    }

    /// The pull request for `branch` in the repository at `directory`, from
    /// `gh pr view`. Nil when `gh` is missing, not signed in, or there is none.
    public static func pullRequest(branch: String, in directory: String, gh: String?) -> LaneRowMetadata.PullRequest? {
        guard let gh, isSafeRefName(branch) else { return nil }
        let output = run(gh, ["pr", "view", "--json", "number,state,isDraft,url", "--", branch], directory: directory)
        return parsePullRequest(output)
    }

    static func parsePullRequest(_ output: String) -> LaneRowMetadata.PullRequest? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["number"] as? Int, let state = object["state"] as? String else { return nil }
        let kind: LaneRowMetadata.PullRequest.State
        switch state.uppercased() {
        case "MERGED": kind = .merged
        case "CLOSED": kind = .closed
        default: kind = (object["isDraft"] as? Bool) == true ? .draft : .open
        }
        // Only a web link is kept, so opening it can never launch something else.
        let url = (object["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return .init(number: number, state: kind, url: url)
    }

    /// Where `gh` is installed, if it is.
    public static func locateGH() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// At most two helper processes run at once across every sweep.
    static let processSlots = DispatchSemaphore(value: 2)

    /// Run a helper at background QoS, waiting for a free slot. Call it off
    /// the main thread and outside Swift's concurrency pool: it blocks.
    static func run(_ executable: String, _ arguments: [String], directory: String? = nil, timeout: TimeInterval = 8) -> String {
        processSlots.wait()
        defer { processSlots.signal() }
        let process = Process()
        process.qualityOfService = .background
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
