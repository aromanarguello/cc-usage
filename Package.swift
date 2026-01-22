// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeUsageTracker",
            path: "Sources/ClaudeUsageTracker"
        )
    ]
)
