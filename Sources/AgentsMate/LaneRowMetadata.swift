import Foundation
import Darwin

/// What a lane's row can show about the work in it: the git branch of its
/// folder, the pull request for that branch, and the TCP ports its programs
/// listen on.
public struct LaneRowMetadata: Equatable, Sendable {
    public struct PullRequest: Equatable, Sendable {
        public enum State: String, Sendable { case open, draft, merged, closed }
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
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        let fm = FileManager.default
        while true {
            let dotGit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    // A worktree or submodule: ".git" names the real folder.
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: path, relativeTo: url).standardizedFileURL
                }
                return parseHead(try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    static func parseHead(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("ref: refs/heads/") { return String(text.dropFirst("ref: refs/heads/".count)) }
        if text.hasPrefix("ref: ") { return String(text.dropFirst("ref: ".count)) }
        return String(text.prefix(7))
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
        guard let gh else { return nil }
        let output = run(gh, ["pr", "view", branch, "--json", "number,state,isDraft,url"], directory: directory)
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
        return .init(number: number, state: kind, url: (object["url"] as? String).flatMap(URL.init(string:)))
    }

    /// Where `gh` is installed, if it is.
    public static func locateGH() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ executable: String, _ arguments: [String], directory: String? = nil, timeout: TimeInterval = 8) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
