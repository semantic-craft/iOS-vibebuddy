#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for iOS-vibebuddy.
#
# The product is a macOS/iOS Swift app, but its shared SwiftPM packages
# (VibeBuddyKit wire model + the vibebuddyd Hummingbird daemon in VibeBuddyMac)
# build, test, and RUN on Linux, and the agent-hook tooling is Python/Bash. This
# installs a Linux Swift toolchain + the C/C++ deps swift-crypto needs, then warms
# the package builds. The Xcode apps (VibeBuddyMacApp / VibeBuddyApp) still require
# a macOS host with Xcode and are not built here.
set -euo pipefail

SWIFT_VERSION="6.3.3"
SWIFT_ROOT="/opt/swift"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\n=== %s ===\n' "$*"; }

log "System dependencies (Swift runtime + swift-crypto C/C++ build)"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
# libstdc++-14-dev matches the GCC toolchain the bundled clang selects, so the
# BoringSSL C++ in swift-crypto finds <memory> and friends.
sudo apt-get install -y --no-install-recommends \
  binutils git curl gnupg2 g++ libstdc++-14-dev \
  libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libstdc++-13-dev \
  libpython3-dev libxml2-dev libz3-dev pkg-config tzdata zlib1g-dev libncurses-dev

if [ ! -x "${SWIFT_ROOT}/usr/bin/swift" ]; then
  log "Installing Swift ${SWIFT_VERSION} (Ubuntu 24.04, x86_64)"
  URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz"
  tmp="$(mktemp -d)"
  for attempt in 1 2 3 4; do
    if curl -fL --retry 3 -o "${tmp}/swift.tar.gz" "$URL"; then break; fi
    echo "download attempt ${attempt} failed; retrying"; sleep $((attempt * 4))
  done
  sudo mkdir -p "$SWIFT_ROOT"
  sudo tar xzf "${tmp}/swift.tar.gz" -C "$SWIFT_ROOT" --strip-components=1
  rm -rf "$tmp"
else
  log "Swift already present at ${SWIFT_ROOT}; skipping download"
fi

log "Linking Swift onto PATH"
sudo ln -sf "${SWIFT_ROOT}/usr/bin/swift" /usr/local/bin/swift
sudo ln -sf "${SWIFT_ROOT}/usr/bin/swiftc" /usr/local/bin/swiftc
sudo ln -sf "${SWIFT_ROOT}/usr/bin/sourcekit-lsp" /usr/local/bin/sourcekit-lsp 2>/dev/null || true
swift --version

log "Building shared package: VibeBuddyKit"
swift build --package-path "${REPO_DIR}/VibeBuddyKit"

log "Building daemon + core: VibeBuddyMac (vibebuddyd)"
swift build --package-path "${REPO_DIR}/VibeBuddyMac"

log "Bootstrap complete. Try:"
echo "  swift test --package-path VibeBuddyKit"
echo "  swift test --package-path VibeBuddyMac"
echo "  VIBEBUDDY_TOKEN=devtoken swift run --package-path VibeBuddyMac vibebuddyd"
echo "  python3 hooks/test_install_agent_hooks.py"
