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
        .package(url: "https://github.com/garmin/fit-swift-sdk.git", from: "21.205.0")
    ],
    targets: [
        .target(
            name: "FitViewCore",
            dependencies: [
                .product(name: "FITSwiftSDK", package: "fit-swift-sdk")
            ]
        ),
        .testTarget(name: "FitViewCoreTests", dependencies: ["FitViewCore"]),
    ]
)
