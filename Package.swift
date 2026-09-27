// swift-tools-version: 6.0
// GoRunner (go-runner) — menu bar runner with brand characters and AI usage monitoring.
// Module layout (each target is owned by one workstream; see CLAUDE.md):
//   GoRunnerCore      shared models, protocols, settings, formatting, process helpers (no dependencies)
//   SystemMetrics  CPU / memory / storage / battery / network sampling
//   RunnerKit      sprite rendering, CALayer runner animation, runner catalog + pack import
//   RunnerArt      built-in pixel sprites (data only)
//   ClaudeUsage    Claude usage provider (statusline hook, OAuth usage opt-in, local JSONL logs)
//   CodexUsage     Codex usage provider (codex app-server, session logs)
//   BedrockUsage   AWS Bedrock usage provider (CloudWatch, Service Quotas, Cost Explorer via aws CLI)
//   GoRunnerApp       AppKit/SwiftUI app shell (status item, status menu, settings, uninstall)
import PackageDescription

let package = Package(
    name: "GoRunner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GoRunner", targets: ["GoRunnerApp"]),
    ],
    targets: [
        .target(name: "GoRunnerCore"),
        .target(name: "SystemMetrics", dependencies: ["GoRunnerCore"]),
        .target(name: "RunnerKit", dependencies: ["GoRunnerCore"]),
        .target(name: "RunnerArt", dependencies: ["GoRunnerCore"]),
        .target(name: "ClaudeUsage", dependencies: ["GoRunnerCore"]),
        .target(name: "CodexUsage", dependencies: ["GoRunnerCore"]),
        .target(name: "BedrockUsage", dependencies: ["GoRunnerCore"]),
        .executableTarget(
            name: "GoRunnerApp",
            dependencies: ["GoRunnerCore", "SystemMetrics", "RunnerKit", "RunnerArt", "ClaudeUsage", "CodexUsage", "BedrockUsage"]
        ),
        .testTarget(name: "GoRunnerCoreTests", dependencies: ["GoRunnerCore"]),
        .testTarget(name: "SystemMetricsTests", dependencies: ["SystemMetrics"]),
        .testTarget(name: "RunnerKitTests", dependencies: ["RunnerKit", "RunnerArt"]),
        .testTarget(name: "RunnerArtTests", dependencies: ["RunnerArt"]),
        // Fixtures are read via #filePath, not bundled as resources.
        .testTarget(name: "ClaudeUsageTests", dependencies: ["ClaudeUsage"], exclude: ["Fixtures"]),
        .testTarget(name: "CodexUsageTests", dependencies: ["CodexUsage"], exclude: ["Fixtures"]),
        .testTarget(name: "BedrockUsageTests", dependencies: ["BedrockUsage"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
