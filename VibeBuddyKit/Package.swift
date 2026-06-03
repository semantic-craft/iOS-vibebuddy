// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeBuddyKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "VibeBuddyKit", targets: ["VibeBuddyKit"]),
    ],
    targets: [
        .target(name: "VibeBuddyKit"),
        .testTarget(name: "VibeBuddyKitTests", dependencies: ["VibeBuddyKit"]),
    ]
)
