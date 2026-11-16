// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentsMate",
    platforms: [.macOS(.v14)],
    products: [
        // Agents mode: the lane sidebar, a live terminal per lane, menus.
        .library(name: "AgentsMate", targets: ["AgentsMate"]),
        // The lane status feed, without AppKit, for anything that reads or writes it.
        .library(name: "AgentsMateStatus", targets: ["AgentsMateStatus"]),
        // Detects installed agent CLIs and updates them with the tool that installed them.
        .library(name: "AgentsMateUpdates", targets: ["AgentsMateUpdates"]),
        // A headless `claude -p` stream-json conversation, for chat surfaces.
        .library(name: "AgentsMateChat", targets: ["AgentsMateChat"]),
        // The hook and notify writer that feeds lane status.
        .executable(name: "agentsmate-status", targets: ["agentsmate-status"]),
    ],
    dependencies: [
        // 1.12 added Metal shaders, which the Command Line Tools cannot compile.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", "1.11.2"..<"1.12.0"),
    ],
    targets: [
        .target(name: "AgentsMateStatus"),
        .target(name: "AgentsMateUpdates"),
        .target(
            name: "AgentsMate",
            dependencies: [
                "AgentsMateStatus",
                "AgentsMateUpdates",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [.copy("Resources/LaneIcons")]
        ),
        .target(name: "AgentsMateChat", dependencies: ["AgentsMateStatus"]),
        .executableTarget(name: "agentsmate-status", dependencies: ["AgentsMateStatus"]),
        .testTarget(name: "AgentsMateStatusTests", dependencies: ["AgentsMateStatus"]),
        .testTarget(name: "AgentsMateUpdatesTests", dependencies: ["AgentsMateUpdates"]),
        .testTarget(name: "AgentsMateTests", dependencies: ["AgentsMate"]),
        .testTarget(name: "AgentsMateChatTests", dependencies: ["AgentsMateChat"]),
    ],
    swiftLanguageModes: [.v6]
)
