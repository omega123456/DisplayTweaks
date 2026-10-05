// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DisplayTweaks",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Tests only (snapshot tests need XCTest, i.e. Xcode: run them with scripts/test.sh).
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.6"),
    ],
    targets: [
        .executableTarget(
            name: "DisplayTweaks",
            path: "Sources/DisplayTweaks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DisplayTweaksTests",
            dependencies: ["DisplayTweaks", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            path: "Tests/DisplayTweaksTests",
            exclude: ["__Snapshots__"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
