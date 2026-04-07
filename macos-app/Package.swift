// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeGraphContext",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CodeGraphContext",
            path: "Sources/CodeGraphContext",
            exclude: ["Info.plist"]
        )
    ]
)
