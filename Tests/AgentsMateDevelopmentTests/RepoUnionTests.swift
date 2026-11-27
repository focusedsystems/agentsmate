import DevMateCore
import Foundation
import Testing
@testable import AgentsMateDevelopment

private let azure = ["dev", "azure", "com"].joined(separator: ".")

@Suite struct RepoUnionTests {
    private func repo(_ id: String, _ path: String, provider: RepoProviderKind = .github) -> DevRepo {
        DevRepo(id: id, name: id, path: path, remote: "o/" + id, provider: provider)
    }

    private func catalog(_ sections: [(String, [DevRepo])]) -> RepoCatalog {
        RepoCatalog(sections: sections.map { RepoSection(name: $0.0, repos: $0.1) })
    }

    @Test func deduplicatesByPathAcrossApps() {
        let one = catalog([("A", [repo("x", "/Users/me/dev/x"), repo("y", "/Users/me/dev/y")])])
        let two = catalog([("B", [repo("x2", "/Users/me/dev/x/"), repo("z", "/Users/me/dev/z")])])
        let union = RepoUnion.merge([one, two]).repos
        #expect(union.map(\.path) == ["/Users/me/dev/x", "/Users/me/dev/y", "/Users/me/dev/z"])
    }

    @Test func pathsCompareWithoutCaseOrDotSegments() {
        let one = catalog([("A", [repo("x", "/Users/me/Dev/X")])])
        let two = catalog([("A", [repo("x2", "/Users/me/dev/./x")])])
        #expect(RepoUnion.merge([one, two]).repos.count == 1)
    }

    @Test func idsStayUniqueWhenDifferentPathsShareOne() {
        let one = catalog([("A", [repo("same", "/a/one")])])
        let two = catalog([("A", [repo("same", "/a/two")])])
        let ids = RepoUnion.merge([one, two]).repos.map(\.id)
        #expect(Set(ids).count == 2)
        #expect(ids.first == "same")
    }

    @Test func sectionsJoinByNameAndEmptyOnesDrop() {
        let one = catalog([("Cloud", [repo("a", "/p/a")])])
        let two = catalog([("Cloud", [repo("b", "/p/b")]), ("Dup", [repo("a2", "/p/a")])])
        let union = RepoUnion.merge([one, two])
        #expect(union.sections.map(\.name) == ["Cloud"])
        #expect(union.repos.count == 2)
    }

    @Test func readsEveryRegistryInTheFolderAndWritesAReadableUnion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("union-" + UUID().uuidString)
        let output = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ id: String, _ repos: [DevRepo]) throws {
            let sections = repos.map { repo in
                #"{"id":"\#(repo.id)","name":"\#(repo.name)","path":"\#(repo.path)","remote":"o/\#(repo.name)","provider":"github","kind":"repo","shared":false,"fork":false,"surfaces":{"agents":true,"development":true,"projects":true}}"#
            }.joined(separator: ",")
            let text = #"{"schema_version":1,"app":{"id":"\#(id)"},"settings":{},"sections":[{"name":"S","repos":[\#(sections)]}]}"#
            try text.write(to: folder.appendingPathComponent(id + ".json"), atomically: true, encoding: .utf8)
        }
        try write("app.one", [repo("a", "/r/a"), repo("b", "/r/b")])
        try write("app.two", [repo("b2", "/r/b"), repo("c", "/r/c")])
        try "not a registry".write(to: folder.appendingPathComponent("app.bad.json"), atomically: true, encoding: .utf8)

        #expect(RepoUnion.registryIDs(in: folder) == ["app.bad", "app.one", "app.two"])
        let union = RepoUnion.load(directory: folder)
        #expect(union.repos.map(\.path) == ["/r/a", "/r/b", "/r/c"])

        #expect(RepoUnion.write(union, to: output))
        let source = RegistryRepoSource(bundleID: RepoUnion.bundleID, fallback: RepoCatalog(sections: []),
                                        directory: output, usesDefaultLastGoodFile: false)
        let read = source.reload()
        #expect(read.state == .registry)
        #expect(read.catalog.repos.map(\.path) == ["/r/a", "/r/b", "/r/c"])
    }

    @Test func findsTheAzureOrganizationInACloneAddress() {
        #expect(AzureOrigin.organization(fromRemote: "https://\(azure)/org/Proj/_git/repo") == "org")
        #expect(AzureOrigin.organization(fromRemote: "https://org@\(azure)/org/Proj/_git/repo\n") == "org")
        #expect(AzureOrigin.organization(fromRemote: "git@ssh.\(azure):v3/org/Proj/repo") == "org")
        #expect(AzureOrigin.organization(fromRemote: "https://acme.visualstudio.com/Proj/_git/repo") == "https://acme.visualstudio.com")
        #expect(AzureOrigin.organization(fromRemote: "https://github.com/o/r") == nil)
        #expect(AzureOrigin.mostCommon(["https://\(azure)/a/P/_git/r", "https://\(azure)/b/P/_git/r",
                                        "https://\(azure)/b/P/_git/s"]) == "b")
    }

    @Test func tabsHaveShortcutsOneToSixAndASavedDefault() {
        #expect(AgentsTab.allCases.map(\.shortcutKey) == ["1", "2", "3", "4", "5", "6"])
        #expect(AgentsTab(saved: "projects") == .projects)
        #expect(AgentsTab(saved: "nonsense") == .agents)
        #expect(AgentsTab(saved: nil) == .agents)
        #expect(AgentsTab(link: .pipeline) == .pipelines)
    }
}
