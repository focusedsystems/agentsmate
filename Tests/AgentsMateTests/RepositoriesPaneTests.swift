import XCTest
import SwiftUI
@testable import AgentsMate

@MainActor
final class RepositoriesPaneTests: XCTestCase {
    private func store() -> AgentLaneStore {
        let config = AgentLaneStore.Configuration(termProgram: "T", sessionFileDirectory: nil, findsDetachedSessions: false,
                                                  showsSectionHeadings: true, defaultRepositoryOrder: [])
        return AgentLaneStore(configuration: config,
                              backends: [CommandLaneBackend(id: "agent", displayName: "Agent", command: "true")],
                              statusFeed: nil,
                              defaults: UserDefaults(suiteName: "agentsmate-pane-\(UUID().uuidString)")!)
    }

    private func pane(count: Int, sectioned: Bool, store: AgentLaneStore) -> some View {
        let lanes = (0..<count).map {
            AgentLane(id: "r\($0)", title: "repo-\($0)", directory: URL(fileURLWithPath: "/w/repo-\($0)"),
                      backendID: "agent", section: sectioned ? "Section \($0 % 3)" : nil)
        }
        store.sync(lanes: lanes)
        let items = lanes.map { AgentRepositoryItem(path: $0.directory.path, title: $0.title, subtitle: "/w/\($0.title)") }
        return Form {
            AgentRepositoriesSection(store: store, items: items) {
                Button("Add Folder…") {}
            }
            Section("Folders") { Text("A section after the list") }
        }
        .formStyle(.grouped)
    }

    func testPaneRendersEveryRowInTheFormsOwnScroll() throws {
        let dir = ProcessInfo.processInfo.environment["AGENTSMATE_RENDER_DIR"]
        for (name, sectioned) in [("flat", false), ("sections", true)] {
            for scheme in [ColorScheme.light, .dark] {
                let view = pane(count: 24, sectioned: sectioned, store: store())
                    .frame(width: 560, height: 1800)
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 1800)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                if let dir, let png = rep.representation(using: .png, properties: [:]) {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("repositories-pane-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
