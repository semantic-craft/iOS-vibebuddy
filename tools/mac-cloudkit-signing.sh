# Sourced by tools/redeploy-mac.sh and tools/release-mac.sh.
#
# CloudKit cues (ADR-0013 direction D) need the iCloud entitlement, and on
# macOS a restricted entitlement is only honoured with an embedded provisioning
# profile that allows it and names the signing certificate. Signing the
# entitlement without such a profile produces an app that macOS refuses to
# launch, so these helpers only ever add it when a matching profile is on disk;
# otherwise the app is signed exactly as before and CloudKit stays off.
#
# Profiles come from tools/fetch-mac-cloudkit-profiles.sh (Xcode automatic
# signing): a development profile for "Apple Development", a Developer ID
# profile for "Developer ID Application".

CLOUDKIT_BUNDLE_ID="${CLOUDKIT_BUNDLE_ID:-com.vibebuddy.mac}"
CLOUDKIT_CONTAINER="iCloud.com.vibebuddy.app"
CLOUDKIT_PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

# cloudkit_identity_sha1 <identity name or 40-hex hash>
cloudkit_identity_sha1() {
  local id="$1"
  if [[ "$id" =~ ^[0-9A-Fa-f]{40}$ ]]; then printf '%s\n' "$id"; return; fi
  security find-identity -p codesigning -v 2>/dev/null \
    | grep -F "\"$id\"" | head -1 | grep -Eo '[0-9A-F]{40}' || true
}

# cloudkit_profile_for <identity> → prints the newest profile for the Mac app
# that allows the cue container and includes that certificate; nothing if none.
cloudkit_profile_for() {
  local sha1; sha1="$(cloudkit_identity_sha1 "$1")"
  [[ -n "$sha1" && -d "$CLOUDKIT_PROFILE_DIR" ]] || return 0
  # A development profile lists the Macs it may run on; the embedded profile
  # must name this one or the app will not launch here.
  local udid; udid="$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/.*Provisioning UDID: *//p')"
  /usr/bin/python3 - "$sha1" "$CLOUDKIT_PROFILE_DIR" "$CLOUDKIT_BUNDLE_ID" "$CLOUDKIT_CONTAINER" "$udid" <<'PY'
import glob, hashlib, os, plistlib, subprocess, sys, datetime
sha1, folder, bundle, container, udid = sys.argv[1].upper(), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
# An embedded profile that expires makes the installed app fail to launch;
# refuse one with less than 30 days left (the fetch script renews it).
cutoff = datetime.datetime.now() + datetime.timedelta(days=30)
best = None
for path in glob.glob(os.path.join(folder, "*.provisionprofile")):
    try:
        raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True, check=True).stdout
        p = plistlib.loads(raw)
    except Exception:
        continue
    ent = p.get("Entitlements", {})
    if not ent.get("com.apple.application-identifier", "").endswith("." + bundle):
        continue
    if container not in ent.get("com.apple.developer.icloud-container-identifiers", []):
        continue
    if p.get("ExpirationDate") and p["ExpirationDate"] < cutoff:
        continue
    if not p.get("ProvisionsAllDevices") and udid not in p.get("ProvisionedDevices", []):
        continue
    certs = [hashlib.sha1(c).hexdigest().upper() for c in p.get("DeveloperCertificates", [])]
    if sha1 not in certs:
        continue
    if best is None or p["CreationDate"] > best[0]:
        best = (p["CreationDate"], path)
if best:
    print(best[1])
PY
}

# cloudkit_entitlements <profile> <base entitlements plist> <out plist>
# The base entitlements plus the ones the profile grants for CloudKit, with
# the environment the profile allows (Developer ID profiles allow Production
# only; development profiles get Development).
cloudkit_entitlements() {
  /usr/bin/python3 - "$1" "$2" "$3" "$CLOUDKIT_CONTAINER" <<'PY'
import plistlib, subprocess, sys
profile, base, out, container = sys.argv[1:5]
p = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", profile], capture_output=True, check=True).stdout)
granted = p["Entitlements"]
with open(base, "rb") as f:
    ent = plistlib.load(f)
ent["com.apple.application-identifier"] = granted["com.apple.application-identifier"]
ent["com.apple.developer.team-identifier"] = granted["com.apple.developer.team-identifier"]
ent["com.apple.developer.icloud-container-identifiers"] = [container]
ent["com.apple.developer.icloud-services"] = ["CloudKit"]
envs = granted.get("com.apple.developer.icloud-container-environment", ["Production"])
envs = envs if isinstance(envs, list) else [envs]
ent["com.apple.developer.icloud-container-environment"] = "Development" if "Development" in envs else "Production"
with open(out, "wb") as f:
    plistlib.dump(ent, f)
print(ent["com.apple.developer.icloud-container-environment"])
PY
}
