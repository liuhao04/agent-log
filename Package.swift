// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AiCliLogApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AiCliLogApp",
            dependencies: ["CSQLite"]
        ),
        .systemLibrary(
            name: "CSQLite"
        )
    ]
)
