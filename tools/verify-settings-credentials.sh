#!/bin/bash
# Runs the actual app credential state with an in-memory store; never uses Keychain.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
verification_dir="$repo_root/.scratch/settings-03/credential-regression"
mkdir -p "$verification_dir/Sources/Regression"
cp "$repo_root/VibeBuddyMacApp/Sources/SettingsCredentials.swift" "$verification_dir/Sources/Regression/"
cp "$repo_root/tools/tests/SettingsCredentialsRegression.swift" "$verification_dir/Sources/Regression/"
cat > "$verification_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CredentialRegression", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../VibeBuddyKit")],
    targets: [.executableTarget(name: "Regression", dependencies: [.product(name: "VibeBuddyKit", package: "VibeBuddyKit")])])
SWIFT
swift run --package-path "$verification_dir" --scratch-path "$verification_dir/.build" -j 2 Regression
