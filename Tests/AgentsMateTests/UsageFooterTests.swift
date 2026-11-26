import SwiftUI
import XCTest
@testable import AgentsMate
@testable import AgentsMateStatus

private struct FixedSource: AgentUsageSource {
    var agent: String
    var usage: AgentUsage?
    var unknownAgent: String? { agent }
    func read() -> AgentUsage? { usage }
}

@MainActor
final class UsageFooterTests: XCTestCase {
    func testStandardSourcesNameBothAgents() {
        XCTAssertEqual(AgentUsageSources.standard().compactMap(\.unknownAgent), ["Claude", "Codex"])
        XCTAssertEqual(AgentLaneStore.Configuration(termProgram: "Test").usageSources.compactMap(\.unknownAgent),
                       ["Claude", "Codex"], "an app that says nothing gets both meters")
    }

    func testFallbackHostsReadOverSSHSkippingThisMacAndUnsafeNames() throws {
        let source = AgentUsageSources.claude(host: "-oProxyCommand=x", fallbackHosts: ["build-host", "this-mac", "build-host", "  "],
                                              selfNames: ["this-mac"])
        let fallback = try XCTUnwrap(source as? FallbackUsageSource)
        XCTAssertTrue(fallback.primary is KeyValueUsageFileSource, "this Mac's own cache is read first")
        let remote = try XCTUnwrap(fallback.fallbacks as? [KeyValueUsageCommandSource])
        XCTAssertEqual(remote.count, 1)
        XCTAssertEqual(remote.first?.command, ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--",
                                               "build-host", "cat " + AgentUsageSources.claudeCachePath])
        XCTAssertEqual(remote.first?.interval, 60)
        XCTAssertTrue(AgentUsageSources.claude(fallbackHosts: ["this-mac"], selfNames: ["this-mac"]) is KeyValueUsageFileSource,
                      "where the fallback host is this Mac there is no ssh")
        XCTAssertTrue(AgentUsageSources.claude(fallbackHosts: [], selfNames: []) is KeyValueUsageFileSource)
    }

    func testAnAgentWithNoReadingStaysAsUnknown() async throws {
        let model = AgentUsageModel(sources: [FixedSource(agent: "Claude", usage: nil)])
        model.refresh()
        for _ in 0..<100 where model.usages.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.usages.map(\.agent), ["Claude"])
        XCTAssertEqual(model.usages.first?.isUnknown, true)
    }

    /// Draws the footer offscreen. Set `AGENTSMATE_RENDER_DIR` to keep the PNGs.
    func testRenderFooter() async throws {
        let now = Date()
        let claude = AgentUsage(agent: "Claude", windows: [
            .init(label: "Session", percent: 34, resetsAt: now.addingTimeInterval(3 * 3600)),
            .init(label: "Week", percent: 72, resetsAt: now.addingTimeInterval(2 * 86400)),
        ], readAt: now)
        let codex = AgentUsage(agent: "Codex", windows: [
            .init(label: "5h", percent: 12, resetsAt: now.addingTimeInterval(4 * 3600)),
        ], readAt: now)
        let cases: [(String, [any AgentUsageSource])] = [
            ("both", [FixedSource(agent: "Claude", usage: claude), FixedSource(agent: "Codex", usage: codex)]),
            ("unknown", [FixedSource(agent: "Claude", usage: nil), FixedSource(agent: "Codex", usage: codex)]),
        ]
        let dir = ProcessInfo.processInfo.environment["AGENTSMATE_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        for (name, sources) in cases {
            let model = AgentUsageModel(sources: sources)
            model.refresh()
            for _ in 0..<100 where model.usages.count < sources.count { try await Task.sleep(nanoseconds: 20_000_000) }
            for scheme in [ColorScheme.light, .dark] {
                let view = AgentUsageFooter(model: model)
                    .frame(width: 260)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                // ImageRenderer draws a native ProgressView as a placeholder, so the
                // footer is drawn by an offscreen hosting view that never joins a window.
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                XCTAssertGreaterThan(size.height, 20)
                if let dir, let png = rep.representation(using: .png, properties: [:]) {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try png.write(to: dir.appendingPathComponent("usage-footer-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
