// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeBuddyMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VibeBuddyMacCore", targets: ["VibeBuddyMacCore"]),
        .executable(name: "vibebuddyd", targets: ["vibebuddyd"]),
    ],
    dependencies: [
        .package(path: "../VibeBuddyKit"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "VibeBuddyMacCore",
            dependencies: [
                .product(name: "VibeBuddyKit", package: "VibeBuddyKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        .executableTarget(
            name: "vibebuddyd",
            dependencies: ["VibeBuddyMacCore"]
        ),
        .testTarget(
            name: "VibeBuddyMacCoreTests",
            dependencies: [
                "VibeBuddyMacCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
