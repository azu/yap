// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "chronixd-capture",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "chronixd-capture", targets: ["chronixd-capture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/tuist/Noora.git", from: "0.40.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "chronixd-capture",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Noora", package: "Noora"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "chronixd-captureTests",
            dependencies: ["chronixd-capture"]
        ),
    ]
)
