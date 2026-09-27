// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeIsland",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "CodeIslandCore",
            path: "Sources/CodeIslandCore"
        ),
        .executableTarget(
            name: "CodeIsland",
            dependencies: [
                "CodeIslandCore",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/CodeIsland",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "codeisland-bridge",
            dependencies: ["CodeIslandCore"],
            path: "Sources/CodeIslandBridge"
        ),
        .testTarget(
            name: "CodeIslandCoreTests",
            dependencies: ["CodeIslandCore"],
            path: "Tests/CodeIslandCoreTests"
        ),
        .testTarget(
            name: "CodeIslandTests",
            dependencies: [
                "CodeIsland",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Tests/CodeIslandTests"
        ),
    ]
)
