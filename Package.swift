// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Music",

    platforms: [
        .macOS(.v13)
    ],

    dependencies: [
        .package(
        url: "https://github.com/apple/swift-collections.git",
        .upToNextMinor(from: "1.2.0") // or `.upToNextMajor
        )
    ],

    targets: [
        .executableTarget(
            name: "Music",
            dependencies: [
                .product(name: "Collections", package: "swift-collections")
            ],
            path: "Sources"
        ),

        .executableTarget(
            name: "WindowSizeTest",
            path: "Tests/window_size"
        )

    ]
)