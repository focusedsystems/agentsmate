import DevMateCore
import Foundation

/// Every repo of every app: the union of the rendered registries in
/// `~/.config/agent-apps/repos`, one entry per checkout path. Which apps and
/// repos exist is read from those files each time, never listed here.
public enum RepoUnion {
    /// This app's own id, under which the union is written for DevMate to read.
    public static let bundleID = "systems.focused.agentsmate"

    /// A path with `.`, `..`, repeated and trailing slashes removed, and case and
    /// Unicode form ignored, as the volume ignores them.
    static func key(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            .decomposedStringWithCanonicalMapping.lowercased()
    }

    /// The registry files in `directory`, by app id, in a stable order.
    public static func registryIDs(in directory: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(5)) }
            .filter { !$0.isEmpty && $0 != bundleID }
            .sorted()
    }

    /// Joins catalogs in order. The first entry for a path wins, sections join
    /// by name, ids stay unique, and settings that name lists are combined.
    public static func merge(_ catalogs: [RepoCatalog]) -> RepoCatalog {
        var seenPaths = Set<String>()
        var usedIDs = Set<String>()
        var sections: [RepoSection] = []
        var protected: [String] = []
        for catalog in catalogs {
            for branch in catalog.settings.protectedBranches ?? [] where !protected.contains(branch) {
                protected.append(branch)
            }
            for section in catalog.sections {
                var kept: [DevRepo] = []
                for var repo in section.repos where seenPaths.insert(key(repo.path)).inserted {
                    var id = repo.id
                    var n = 2
                    while !usedIDs.insert(id).inserted { id = "\(repo.id)~\(n)"; n += 1 }
                    repo.id = id
                    kept.append(repo)
                }
                guard !kept.isEmpty else { continue }
                if let at = sections.firstIndex(where: { $0.name == section.name }) {
                    sections[at].repos += kept
                } else {
                    sections.append(RepoSection(name: section.name, repos: kept))
                }
            }
        }
        var settings = catalogs.first?.settings ?? RepoSettings()
        settings.protectedBranches = protected.isEmpty ? nil : protected
        return RepoCatalog(settings: settings, sections: sections)
    }

    /// The union of what is in `directory` now. A file that cannot be read as
    /// an app's registry is left out rather than failing the rest.
    public static func load(directory: URL = RegistryRepoSource.defaultDirectory) -> RepoCatalog {
        let catalogs = registryIDs(in: directory).compactMap { id -> RepoCatalog? in
            let source = RegistryRepoSource(bundleID: id, fallback: RepoCatalog(sections: []), directory: directory,
                                            usesDefaultLastGoodFile: false)
            let snapshot = source.reload()
            guard snapshot.state == .registry else { return nil }
            return snapshot.catalog
        }
        return merge(catalogs)
    }

    private struct File: Encodable {
        struct App: Encodable { var id: String }
        var schema_version = DevMate.registrySchemaVersion
        var app = App(id: RepoUnion.bundleID)
        var settings: RepoSettings
        var sections: [RepoSection]
    }

    /// Writes `catalog` as a registry file for this app, only when it changed,
    /// so DevMate's source reads the union like any app's registry. Returns
    /// whether the file now matches.
    @discardableResult
    public static func write(_ catalog: RepoCatalog, to directory: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(File(settings: catalog.settings, sections: catalog.sections)) else { return false }
        let file = directory.appendingPathComponent(bundleID + ".json")
        if let old = try? Data(contentsOf: file), old == data { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Where the union is written: this app's own folder, never the shared one.
    public static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentsMate", isDirectory: true)
    }
}
