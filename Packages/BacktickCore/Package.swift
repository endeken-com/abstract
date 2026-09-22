// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BacktickCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BacktickCore", targets: ["BacktickCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BacktickCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "BacktickCoreTests",
            dependencies: ["BacktickCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
