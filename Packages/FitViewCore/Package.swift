// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FitViewCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "FitViewCore", targets: ["FitViewCore"])
    ],
    dependencies: [
        // Wraps Garmin's official C SDK. Chosen over the pure-Swift
        // `garmin/fit-swift-sdk` purely on decode speed — see `FitDecoder.swift`.
        .package(url: "https://github.com/roznet/FitFileParser.git", from: "1.5.2")
    ],
    targets: [
        .target(
            name: "FitViewCore",
            dependencies: [
                .product(name: "FitFileParser", package: "FitFileParser")
            ]
        ),
        .testTarget(name: "FitViewCoreTests", dependencies: ["FitViewCore"]),
    ]
)
