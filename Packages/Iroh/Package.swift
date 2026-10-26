// swift-tools-version: 5.9
import PackageDescription

// Pinned upstream bindings; scripts/prepare-iroh.sh supplies the matching binary.
let package = Package(
    name: "IrohLib", platforms: [.macOS("15.0"), .iOS(.v15)],
    products: [.library(name: "IrohLib", targets: ["IrohLib"])],
    targets: [
        .binaryTarget(name: "Iroh", path: "Iroh.xcframework"),
        .target(name: "IrohLib", dependencies: ["Iroh"], linkerSettings: [
            .linkedFramework("SystemConfiguration"), .linkedFramework("Network"),
            .linkedFramework("CoreWLAN", .when(platforms: [.macOS]))
        ])
    ]
)
