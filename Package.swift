// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentsMate",
    platforms: [.macOS("27.0")],
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
        // The dashboard app: every agent on every Mac, across apps. build-app.sh bundles it.
        .executable(name: "AgentsMateApp", targets: ["AgentsMateApp"]),
    ],
    dependencies: [
        // 1.12 added Metal shaders, which the Command Line Tools cannot compile.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", "1.11.2"..<"1.12.0"),
        // The Development and Projects views AgentsMate.app shows over every app's repos.
        .package(url: "https://github.com/focusedsystems/devmate.git", revision: "0af89ac68c2ae66b904659d1ad51c7418fca6965"),
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
        .target(
            name: "AgentsMateDevelopment",
            dependencies: [
                "AgentsMateStatus",
                .product(name: "DevMateCore", package: "devmate"),
                .product(name: "DevMateAzure", package: "devmate"),
                .product(name: "DevMateGitHub", package: "devmate"),
                .product(name: "DevMateUI", package: "devmate"),
            ]
        ),
        .executableTarget(name: "AgentsMateApp", dependencies: ["AgentsMate", "AgentsMateDevelopment", "AgentsMateStatus"],
                          exclude: ["Resources"]),
        .testTarget(name: "AgentsMateStatusTests", dependencies: ["AgentsMateStatus"]),
        .testTarget(name: "AgentsMateUpdatesTests", dependencies: ["AgentsMateUpdates"]),
        .testTarget(name: "AgentsMateTests", dependencies: ["AgentsMate"]),
        .testTarget(name: "AgentsMateDevelopmentTests",
                    dependencies: ["AgentsMateDevelopment", "AgentsMateStatus", .product(name: "DevMateCore", package: "devmate")]),
        .testTarget(name: "AgentsMateChatTests", dependencies: ["AgentsMateChat"]),
    ],
    swiftLanguageModes: [.v6]
)
