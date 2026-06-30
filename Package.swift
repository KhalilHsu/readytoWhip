// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReadyToWhip",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ReadyToWhip", targets: ["ReadyToWhip"])
    ],
    targets: [
        .executableTarget(
            name: "ReadyToWhip",
            path: "Sources/ReadyToWhip",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
