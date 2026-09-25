#!/usr/bin/env bash
# One-time (and yearly for the development profile): have Xcode's automatic
# signing create the provisioning profiles that let the Mac app use CloudKit
# cues (ADR-0013 direction D). Builds a throwaway stub with the Mac app's
# bundle ID and the iCloud entitlement, so Xcode registers the App ID's iCloud
# capability and downloads:
#   - "Mac Team Provisioning Profile: com.vibebuddy.mac"  (Apple Development)
#   - "Mac Team Direct Provisioning Profile: com.vibebuddy.mac"  (Developer ID)
# into ~/Library/Developer/Xcode/UserData/Provisioning Profiles, where
# tools/mac-cloudkit-signing.sh finds them. Needs the Xcode account signed in.
set -euo pipefail
# An E2E acceptance copy (com.vibebuddy.e2e.<id>) needs its own development
# profile: BUNDLE_ID=com.vibebuddy.e2e.<id> DEVELOPMENT_ONLY=1 tools/fetch-mac-cloudkit-profiles.sh
BUNDLE_ID="${BUNDLE_ID:-com.vibebuddy.mac}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-cloudkit-profiles.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Stub"
cat > "$WORK/Stub/main.swift" <<'SWIFT'
print("stub")
SWIFT
cat > "$WORK/project.yml" <<YML
name: Stub
options: { deploymentTarget: { macOS: "14.0" } }
targets:
  Stub:
    type: application
    platform: macOS
    sources: [Stub]
    info: { path: Stub/Info.plist }
    entitlements:
      path: Stub/Stub.entitlements
      properties:
        com.apple.developer.icloud-container-identifiers: [iCloud.com.vibebuddy.app]
        com.apple.developer.icloud-services: [CloudKit]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID
        DEVELOPMENT_TEAM: LQAVR62TK2
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
YML
cd "$WORK"
xcodegen generate >/dev/null
echo "▸ development profile (Apple Development)…"
xcodebuild -project Stub.xcodeproj -scheme Stub -configuration Debug -derivedDataPath dd \
  -allowProvisioningUpdates build -quiet
if [[ "${DEVELOPMENT_ONLY:-}" == 1 ]]; then echo "✓ development profile for $BUNDLE_ID"; exit 0; fi
echo "▸ Developer ID profile…"
xcodebuild -project Stub.xcodeproj -scheme Stub -configuration Release -derivedDataPath dd \
  -archivePath Stub.xcarchive -allowProvisioningUpdates archive -quiet
cat > export.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>LQAVR62TK2</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath Stub.xcarchive -exportOptionsPlist export.plist \
  -exportPath export -allowProvisioningUpdates -quiet
echo "✓ profiles:"
grep -l "$BUNDLE_ID<" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile 2>/dev/null \
  | while read -r f; do security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - ; done
