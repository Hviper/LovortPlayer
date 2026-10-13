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
        .package(url: "https://github.com/SDWebImage/libdav1d-Xcode.git", exact: "1.1.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")
    ],
    targets: [
        .target(
            name: "LovortPlayerCore",
            dependencies: [
                .product(name: "libdav1d", package: "libdav1d-Xcode"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
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
