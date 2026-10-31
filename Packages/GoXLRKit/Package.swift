// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GoXLRKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GoXLRKit", targets: ["GoXLRKit"]),
    ],
    targets: [
        // The driver's user-client interface; the dext includes the same header.
        .target(name: "XLRDriverABI"),
        .target(name: "GoXLRKit", dependencies: ["XLRDriverABI"], linkerSettings: [.linkedFramework("IOKit")]),
        .testTarget(name: "GoXLRKitTests", dependencies: ["GoXLRKit", "XLRDriverABI"]),
    ]
)
