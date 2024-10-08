// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TinyStorage",
    platforms: [.iOS(.v17), .tvOS(.v17), .visionOS(.v1), .watchOS(.v10)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "TinyStorage",
type: .dynamic,
            targets: ["TinyStorage"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TinyStorage",
            dependencies: []
        ),
    ]
)
