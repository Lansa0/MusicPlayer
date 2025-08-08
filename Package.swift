// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Music",

    platforms: [
        .macOS(.v13)
    ],

    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMinor(from: "1.2.0")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.4"),
    ],

    targets: [
        .executableTarget(
            name: "Music",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "Sources"
        ),

        .executableTarget(
            name: "WindowSizeTest",
            path: "Tests/window_size"
        ),

        .executableTarget(
            name: "UrlSerial",
            path: "Tests/url_serialization",
            exclude: ["files.json"]
        ),

        .executableTarget(
            name: "Scroll",
            path: "Tests/scrolling"
        ),

        .executableTarget(
            name: "History",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "Tests/history"
        ),

        .executableTarget(
            name: "scratch",
            path: "Tests/scratchpad"
        ),

        .executableTarget(
            name: "time",
            path: "Tests/time_bar"
        )

    ]
)