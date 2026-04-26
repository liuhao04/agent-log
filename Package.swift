// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexLogApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "CodexLogApp",
            dependencies: ["CSQLite"]
        ),
        .systemLibrary(
            name: "CSQLite"
        )
    ]
)
