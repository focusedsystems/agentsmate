import Foundation

/// The outcome of running one process.
public struct AgentCLIRunResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// A process to run to update one CLI.
public struct AgentCLIUpdateCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    /// The command as a person would type it.
    public var displayString: String { ([executable] + arguments).joined(separator: " ") }
}

/// Finds installed agent CLIs and updates them with the tool that installed them.
/// It never installs a CLI that is absent, never uses sudo, and never prompts.
public struct AgentCLIUpdater: Sendable {
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]) async -> AgentCLIRunResult

    public var home: String
    public var searchDirectories: [String]
    public var runner: Runner
    public var isExecutable: @Sendable (String) -> Bool
    public var realpath: @Sendable (String) -> String
    public var now: @Sendable () -> Date

    public init(
        home: String = NSHomeDirectory(),
        searchDirectories: [String]? = nil,
        runner: @escaping Runner = AgentCLIUpdater.processRunner,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        realpath: @escaping @Sendable (String) -> String = AgentCLIUpdater.resolveSymlinks,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.searchDirectories = searchDirectories ?? Self.defaultSearchDirectories(home: home)
        self.runner = runner
        self.isExecutable = isExecutable
        self.realpath = realpath
        self.now = now
    }

    /// The folders a login shell usually puts on PATH.
    public static func defaultSearchDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin", "\(home)/bin", "\(home)/.npm-global/bin", "\(home)/.claude/local",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
    }

    // MARK: Decisions

    public func locate(_ cli: AgentCLI) -> AgentCLIInstall? {
        for dir in searchDirectories {
            let path = dir + "/" + cli.binaryName
            guard isExecutable(path) else { continue }
            return AgentCLIInstallInference.infer(
                cli: cli, path: path, resolvedPath: realpath(path), home: home)
        }
        return nil
    }

    /// The command that updates this install, or nil when the method has no safe command.
    public func command(for install: AgentCLIInstall) -> AgentCLIUpdateCommand? {
        var env = ["NONINTERACTIVE": "1"]
        switch install.method {
        case .homebrewCask, .homebrewFormula:
            guard let name = install.packageName, let prefix = install.prefix else { return nil }
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            let args = install.method == .homebrewCask ? ["upgrade", "--cask", name] : ["upgrade", name]
            return AgentCLIUpdateCommand(executable: prefix + "/bin/brew", arguments: args, environment: env)
        case .npmGlobal:
            guard let prefix = install.prefix else { return nil }
            return AgentCLIUpdateCommand(
                executable: prefix + "/bin/npm",
                arguments: ["install", "-g", install.cli.npmPackage + "@latest"], environment: env)
        case .claudeNative:
            return AgentCLIUpdateCommand(executable: install.path, arguments: ["update"], environment: env)
        case .unknown:
            return nil
        }
    }

    // MARK: Running

    public func checkAndUpdate(_ clis: [AgentCLI]) async -> [AgentCLIStatus] {
        var results: [AgentCLIStatus] = []
        for cli in clis { results.append(await checkAndUpdate(cli)) }
        return results
    }

    func checkAndUpdate(_ cli: AgentCLI) async -> AgentCLIStatus {
        let checked = now()
        guard let install = locate(cli) else {
            return AgentCLIStatus(cli: cli, installed: false, lastChecked: checked, message: "Not installed")
        }
        var status = AgentCLIStatus(
            cli: cli, installed: true, path: install.path, method: install.method, lastChecked: checked)
        let before = await version(of: install.path)
        status.version = before

        guard let command = command(for: install) else {
            status.message = "Installed outside Homebrew, npm or the native installer; update it where you installed it"
            return status
        }
        guard isExecutable(command.executable) else {
            status.message = "Update failed: \(command.executable) not found"
            return status
        }

        let result = await runner(command.executable, command.arguments, environment(adding: command.environment, install: install))
        guard result.exitCode == 0 else {
            status.message = "Update failed: \(Self.failureSummary(result))"
            return status
        }

        let after = await version(of: install.path)
        status.version = after ?? before
        if let before, let after, before != after {
            status.message = "Updated \(before) → \(after)"
            status.lastUpdated = now()
        } else {
            status.message = "Up to date"
        }
        return status
    }

    func version(of binary: String) async -> String? {
        let result = await runner(binary, ["--version"], environment(adding: [:], install: nil))
        guard result.exitCode == 0 else { return nil }
        return Self.parseVersion(result.stdout)
    }

    func environment(adding extra: [String: String], install: AgentCLIInstall?) -> [String: String] {
        var dirs = searchDirectories
        if let prefix = install?.prefix { dirs.insert(prefix + "/bin", at: 0) }
        var env = extra
        env["PATH"] = (dirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        return env
    }

    // MARK: Parsing

    public static func parseVersion(_ output: String) -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"\d+(\.\d+)+([-+][0-9A-Za-z.-]+)?"#, options: .regularExpression) {
            return String(text[range])
        }
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init)
        return first?.isEmpty == false ? first : nil
    }

    static func failureSummary(_ result: AgentCLIRunResult) -> String {
        let lines = (result.stderr + "\n" + result.stdout)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let line = lines.first(where: { $0.lowercased().contains("error") }) ?? lines.first
        return line.map { String($0.prefix(200)) } ?? "exit code \(result.exitCode)"
    }

    // MARK: Defaults

    public static func resolveSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Runs a process with no stdin, merging `environment` over the current one.
    public static let processRunner: Runner = { executable, arguments, environment in
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                process.standardInput = FileHandle.nullDevice
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    continuation.resume(returning: AgentCLIRunResult(exitCode: 127, stderr: error.localizedDescription))
                    return
                }
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: AgentCLIRunResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
