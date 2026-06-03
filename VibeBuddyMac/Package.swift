// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeBuddyMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VibeBuddyMacCore", targets: ["VibeBuddyMacCore"]),
    ],
    dependencies: [
        .package(path: "../VibeBuddyKit"),
    ],
    targets: [
        .target(
            name: "VibeBuddyMacCore",
            dependencies: [.product(name: "VibeBuddyKit", package: "VibeBuddyKit")]
        ),
        .testTarget(
            name: "VibeBuddyMacCoreTests",
            dependencies: ["VibeBuddyMacCore"]
        ),
    ]
)
