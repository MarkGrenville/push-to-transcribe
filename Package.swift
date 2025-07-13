// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "MacWhisper",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(
            name: "MacWhisper",
            targets: ["MacWhisper"]
        )
    ],
    dependencies: [
        // Add any external dependencies here if needed
    ],
    targets: [
        .executableTarget(
            name: "MacWhisper",
            dependencies: [],
            path: "Sources/MacWhisper",
            resources: [
                .process("Resources")
            ]
        )
    ]
) 