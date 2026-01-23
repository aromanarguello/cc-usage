// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeCodeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeCodeUsage",
            path: "Sources/ClaudeCodeUsage"
        )
    ]
)
