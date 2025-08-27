// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "PushToTranscribe",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(
            name: "PushToTranscribe",
            targets: ["PushToTranscribe"]
        )
    ],
    dependencies: [
        // Add any external dependencies here if needed
    ],
    targets: [
        .executableTarget(
            name: "PushToTranscribe",
            dependencies: [],
            path: "Sources/PushToTranscribe",
            resources: [
                .process("Resources")
            ]
        )
    ]
) 