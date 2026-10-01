#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
package="$root/.scratch/agent-integration-regression"
mkdir -p "$package/Sources/Regression"
cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Regression", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../VibeBuddyKit")],
    targets: [.executableTarget(name: "Regression", dependencies: [
        .product(name: "VibeBuddyKit", package: "VibeBuddyKit")])])
SWIFT
ln -sf "$root/VibeBuddyMacApp/Sources/AgentIntegrationStatus.swift" "$package/Sources/Regression/AgentIntegrationStatus.swift"
ln -sf "$root/tools/tests/AgentIntegrationRegression.swift" "$package/Sources/Regression/AgentIntegrationRegression.swift"
swift run --package-path "$package" Regression "$@"
