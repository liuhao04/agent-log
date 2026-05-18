// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentLogApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AgentLogApp",
            dependencies: ["CSQLite"]
        ),
        .systemLibrary(
            name: "CSQLite"
        )
    ]
)
