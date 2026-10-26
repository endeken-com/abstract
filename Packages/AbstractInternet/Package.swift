// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AbstractInternet", platforms: [.macOS(.v15), .iOS(.v15)],
    products: [.library(name: "AbstractInternet", targets: ["AbstractInternet"])],
    dependencies: [.package(path: "../Iroh"), .package(path: "../AbstractCore")],
    targets: [.target(name: "AbstractInternet", dependencies: [.product(name: "IrohLib", package: "Iroh")]),
              .testTarget(name: "AbstractInternetTests", dependencies: ["AbstractInternet", "AbstractCore"])]
)
