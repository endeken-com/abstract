// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AbstractCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AbstractCore", targets: ["AbstractCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "AbstractCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "AbstractCoreTests",
            dependencies: ["AbstractCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
