import AgentsMateStatus
import DevMateAzure
import DevMateCore
import DevMateGitHub
import DevMateUI
import Foundation
import SwiftUI

/// Which host's repos a view lists.
public enum DevelopmentHost: String, CaseIterable, Identifiable, Sendable {
    case github = "GitHub"
    case azure = "Azure DevOps"

    public var id: String { rawValue }
    var kind: RepoProviderKind { self == .github ? .github : .azureDevOps }
}

/// Where an Azure DevOps organisation shows in a repository's own `origin`.
public enum AzureOrigin {
    /// The hosted service's address, written in pieces like DevMate's.
    static let serviceHost = ["dev", "azure", "com"].joined(separator: ".")

    /// The organisation in a clone address, as `AzureCLI` takes it: a name, or
    /// the full address for an `*.visualstudio.com` account. Nil for any other
    /// remote.
    public static func organization(fromRemote remote: String) -> String? {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("git@") || text.hasPrefix("ssh://") {
            // The ssh form: v3/<organisation>/<project>/<repo> on the service's ssh host.
            guard text.contains("ssh." + serviceHost) else { return nil }
            let parts = text.components(separatedBy: "v3/").last?.split(separator: "/") ?? []
            return parts.count >= 3 ? String(parts[0]) : nil
        }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        if host == serviceHost {
            let parts = url.pathComponents.filter { $0 != "/" }
            return parts.count >= 2 ? parts[0] : nil
        }
        if host.hasSuffix(".visualstudio.com"), url.pathComponents.contains("_git") {
            return "https://" + host
        }
        return nil
    }

    /// The most common organisation among `remotes`; the first wins a tie.
    public static func mostCommon(_ remotes: [String]) -> String? {
        let found = remotes.compactMap(organization(fromRemote:))
        var best: String?
        var bestCount = 0
        for name in found where name != best {
            let count = found.filter { $0 == name }.count
            if count > bestCount { best = name; bestCount = count }
        }
        return best
    }
}

/// The Development and Projects views over every repo of every app. It reads the
/// union of the app registries, hands it to DevMate as one registry of its own,
/// and keeps a model per host that has repos.
@MainActor
public final class DevelopmentHub: ObservableObject {
    public let development: [DevelopmentHost: DevelopmentModel]
    public let projects: [DevelopmentHost: ProjectsModel]
    private let source: RegistryRepoSource
    private let outputDirectory: URL
    private let registryDirectory: URL
    /// What the toolbar's refresh does for the view that is open.
    public var currentTab: AgentsTab = .agents
    public var currentHost: DevelopmentHost = .github

    public var hosts: [DevelopmentHost] { DevelopmentHost.allCases.filter { development[$0] != nil } }

    public init(registryDirectory: URL = RegistryRepoSource.defaultDirectory,
                outputDirectory: URL = RepoUnion.defaultOutputDirectory) {
        self.registryDirectory = registryDirectory
        self.outputDirectory = outputDirectory
        let catalog = RepoUnion.load(directory: registryDirectory)
        RepoUnion.write(catalog, to: outputDirectory)
        source = RegistryRepoSource(bundleID: RepoUnion.bundleID, fallback: catalog, directory: outputDirectory,
                                    usesDefaultLastGoodFile: false)
        let protected = Set(catalog.settings.protectedBranches ?? ["main", "master"])
        let cache = DiskCache(namespace: RepoUnion.bundleID)

        var development: [DevelopmentHost: DevelopmentModel] = [:]
        var projects: [DevelopmentHost: ProjectsModel] = [:]
        let hosted = catalog.repos.filter { $0.kind == .repo && $0.remote != nil }

        let github = hosted.filter { $0.provider == .github }
        if !github.isEmpty {
            let owner = Self.mainOwner(github)
            development[.github] = DevelopmentModel(
                provider: GitHubDevelopmentProvider(defaultOwner: owner), source: source, protectedBranches: protected,
                cache: cache, defaults: Self.defaults("github"))
            let containers = github.filter(\.surfaces.projects).compactMap { repo -> String? in
                let parts = (repo.remote ?? "").split(separator: "/")
                return parts.count == 2 && String(parts[0]) == owner ? String(parts[1]) : nil
            }
            projects[.github] = ProjectsModel(
                provider: GitHubProjectsProvider(gh: GitHubCLI(owner: owner)),
                configuration: ProjectsConfiguration(containers: containers, defaultsPrefix: "projects.github.",
                                                     cache: cache, lanePolicy: LanePromptPolicy(owner: owner)),
                defaults: Self.defaults("github"))
        }
        let azure = hosted.filter { $0.provider == .azureDevOps }
        if !azure.isEmpty, let organization = AzureOrigin.mostCommon(azure.prefix(8).compactMap { Self.origin(of: $0.path) }) {
            development[.azure] = DevelopmentModel(
                provider: AzureDevelopmentProvider(organization: organization), source: source,
                protectedBranches: protected, cache: DiskCache(namespace: RepoUnion.bundleID + ".azure"),
                defaults: Self.defaults("azure"))
            projects[.azure] = ProjectsModel(
                provider: AzureProjectsProvider(organization: organization,
                                                projects: AzureProjectsProvider.containers(in: catalog)),
                configuration: ProjectsConfiguration(containers: AzureProjectsProvider.containers(in: catalog),
                                                     defaultsPrefix: "projects.azure.",
                                                     cache: DiskCache(namespace: RepoUnion.bundleID + ".azure")),
                defaults: Self.defaults("azure"))
        }
        self.development = development
        self.projects = projects
    }

    private static func defaults(_ host: String) -> UserDefaults {
        UserDefaults(suiteName: RepoUnion.bundleID + "." + host) ?? .standard
    }

    private static func origin(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "remote", "get-url", "origin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// The owner with the most repos; ties go to the first one listed.
    static func mainOwner(_ repos: [DevRepo]) -> String {
        let owners = repos.compactMap { repo -> String? in
            let parts = (repo.remote ?? "").split(separator: "/")
            return parts.count == 2 ? String(parts[0]) : nil
        }
        var best = ""
        var bestCount = 0
        for owner in owners where owner != best {
            let count = owners.filter { $0 == owner }.count
            if count > bestCount { best = owner; bestCount = count }
        }
        return best
    }

    /// The model whose views `tab` shows for `host`; Repos lists every repo, so
    /// any model serves it.
    func model(for host: DevelopmentHost) -> DevelopmentModel? {
        development[host] ?? hosts.first.flatMap { development[$0] }
    }

    /// Reads the app registries again and rewrites the union only if it
    /// changed, so DevMate's lists see a new repo without a restart.
    public func reloadUnion() {
        RepoUnion.write(RepoUnion.load(directory: registryDirectory), to: outputDirectory)
    }

    /// ⌘R: reads the open view now, however recent its last read.
    public func refresh() {
        reloadUnion()
        if currentTab == .projects {
            projects[currentHost]?.refreshIfOlder(than: 0)
        } else {
            model(for: currentHost)?.refreshIfOlder(than: 0)
        }
    }

    /// Shows what an `agentsmate://` link names: the host's list, narrowed to it.
    public func focus(_ kind: AgentsMateLink.Kind, on web: URL) -> DevelopmentHost {
        let host: DevelopmentHost = web.host?.lowercased() == "github.com" ? .github : .azure
        guard let model = development[host] else { return hosts.first ?? host }
        UserDefaults.standard.set(host.rawValue, forKey: "developmentHost")
        model.repoFilter = nil
        model.search = AgentsMateLink.identifier(of: web).map { kind == .pull ? "#" + $0 : $0 } ?? ""
        return host
    }
}
