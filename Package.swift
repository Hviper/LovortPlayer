// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LovortPlayer",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "LovortPlayerCore",
            targets: ["LovortPlayerCore"]
        ),
        .library(
            name: "LovortPlayerUI",
            targets: ["LovortPlayerUI"]
        )
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "LovortPlayerCore",
            path: "Core"
        ),
        .target(
            name: "LovortPlayerUI",
            dependencies: ["LovortPlayerCore"],
            path: "Views"
        ),
        .testTarget(
            name: "LovortPlayerTests",
            dependencies: ["LovortPlayerCore"],
            path: "Tests"
        )
    ]
)
