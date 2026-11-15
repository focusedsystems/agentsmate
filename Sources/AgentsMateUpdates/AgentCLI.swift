import Foundation

/// A command-line agent the package can keep current.
public enum AgentCLI: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The npm package that ships this CLI.
    public var npmPackage: String {
        switch self {
        case .claude: "@anthropic-ai/claude-code"
        case .codex: "@openai/codex"
        }
    }

    /// The executable name looked up on PATH.
    public var binaryName: String { rawValue }

    /// A command that installs the CLI from scratch.
    public var installCommand: String { "npm install -g \(npmPackage)@latest" }
}

/// How an installed CLI got onto the machine, which decides how it updates.
public enum AgentCLIInstallMethod: String, Codable, Sendable {
    case homebrewCask
    case homebrewFormula
    case npmGlobal
    case claudeNative
    case unknown

    public var displayName: String {
        switch self {
        case .homebrewCask: "Homebrew cask"
        case .homebrewFormula: "Homebrew formula"
        case .npmGlobal: "npm global"
        case .claudeNative: "Native installer"
        case .unknown: "Unknown"
        }
    }
}

/// A located CLI: where it was found, where it really lives, and how it was installed.
public struct AgentCLIInstall: Equatable, Sendable {
    public var cli: AgentCLI
    /// The path found on the search path.
    public var path: String
    /// The path after resolving symlinks.
    public var resolvedPath: String
    public var method: AgentCLIInstallMethod
    /// The cask token, formula name or npm package, when the method has one.
    public var packageName: String?
    /// The Homebrew or npm prefix the install lives under, so the update uses the same tool.
    public var prefix: String?

    public init(
        cli: AgentCLI, path: String, resolvedPath: String,
        method: AgentCLIInstallMethod, packageName: String? = nil, prefix: String? = nil
    ) {
        self.cli = cli
        self.path = path
        self.resolvedPath = resolvedPath
        self.method = method
        self.packageName = packageName
        self.prefix = prefix
    }
}

/// Infers the install method from a symlink-resolved path.
public enum AgentCLIInstallInference {
    public static func infer(
        cli: AgentCLI, path: String, resolvedPath: String, home: String
    ) -> AgentCLIInstall {
        func make(_ method: AgentCLIInstallMethod, _ name: String? = nil, _ prefix: String? = nil) -> AgentCLIInstall {
            AgentCLIInstall(
                cli: cli, path: path, resolvedPath: resolvedPath,
                method: method, packageName: name, prefix: prefix)
        }

        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        let parts = resolvedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        func prefix(before index: Int) -> String {
            "/" + parts[..<index].joined(separator: "/")
        }

        for nativeRoot in ["\(home)/.local/share/claude/", "\(home)/.claude/local/"]
        where resolvedPath.hasPrefix(nativeRoot) {
            return make(.claudeNative)
        }

        if let i = parts.firstIndex(of: "Caskroom"), i + 1 < parts.count - 1 {
            return make(.homebrewCask, parts[i + 1], prefix(before: i))
        }
        if let i = parts.firstIndex(of: "Cellar"), i + 1 < parts.count - 1 {
            return make(.homebrewFormula, parts[i + 1], prefix(before: i))
        }
        if let i = parts.indices.first(where: {
            $0 >= 1 && $0 + 1 < parts.count && parts[$0] == "node_modules" && parts[$0 - 1] == "lib"
        }) {
            var name = parts[i + 1]
            if name.hasPrefix("@"), i + 2 < parts.count { name += "/" + parts[i + 2] }
            return make(.npmGlobal, name, prefix(before: i - 1))
        }
        return make(.unknown)
    }
}
