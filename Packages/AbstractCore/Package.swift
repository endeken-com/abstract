// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AbstractCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AbstractCore", targets: ["AbstractCore"]),
        .executable(name: "abstract", targets: ["AbstractCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "AbstractCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // `abstract`, the command line. The app embeds it too (project.yml).
        .executableTarget(name: "AbstractCLI", dependencies: ["AbstractCore"]),
        .testTarget(
            name: "AbstractCoreTests",
            // The CLI tests run the built `abstract`.
            dependencies: ["AbstractCore", "AbstractCLI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
