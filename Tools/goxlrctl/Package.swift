// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "goxlrctl",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/GoXLRKit")],
    targets: [
        .executableTarget(name: "goxlrctl", dependencies: [.product(name: "GoXLRKit", package: "GoXLRKit")]),
    ]
)
