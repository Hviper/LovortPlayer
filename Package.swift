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
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/kingslay/KSPlayer.git", exact: "2.3.4"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(
            name: "LovortPlayerCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "KSPlayer", package: "KSPlayer"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Core"
        ),
        .target(
            name: "LovortPlayerUI",
            dependencies: [
                "LovortPlayerCore",
                .product(name: "KSPlayer", package: "KSPlayer")
            ],
            path: "Views"
        ),
        .testTarget(
            name: "LovortPlayerTests",
            dependencies: ["LovortPlayerCore"],
            path: "Tests"
        )
    ]
)
