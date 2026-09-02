#!/usr/bin/env bash
# Store Apple notarization credentials in the login Keychain, via native dialogs.
#
# Why this exists: notarizing needs an App Store Connect API key, and the person
# holding that key should not have to hand-type a long xcrun invocation — nor
# paste the key anywhere an agent can read it. This asks for the three pieces in
# macOS dialogs and hands them straight to Apple's own tool.
#
#   tools/store-notary-credentials.sh [profile]      # profile defaults to xw-notary
#
# The .p8 is chosen with a file picker and passed to notarytool by *path*: its
# contents are never read here, never echoed, and never reach the process list.
# Only the profile name is printed on success.
set -euo pipefail

PROFILE="${1:-xw-notary}"
PORTAL="https://appstoreconnect.apple.com/access/integrations/api"
TITLE="vibebuddy notarization"

cancelled() { echo "Cancelled — nothing was stored." >&2; exit 1; }

# Dialog results come back on stdout; our own chatter goes to stderr, so a
# cancelled dialog can never be mistaken for a value.
ask() { # ask <prompt> [default]
  osascript \
    -e "display dialog \"$1\" default answer \"${2:-}\" with title \"$TITLE\" buttons {\"Cancel\",\"OK\"} default button \"OK\"" \
    -e 'text returned of result' 2>/dev/null
}

choose() { # choose <prompt> <button…> — echoes the button pressed
  local prompt="$1"; shift
  local buttons="" b
  for b in "$@"; do buttons+="\"$b\","; done
  osascript \
    -e "display dialog \"$prompt\" with title \"$TITLE\" buttons {${buttons%,}} default button \"${*: -1}\"" \
    -e 'button returned of result' 2>/dev/null
}

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  choose "A notarization profile named \\\"$PROFILE\\\" already works.\n\nRe-storing it overwrites the existing one." \
    "Cancel" "Overwrite" >/dev/null || cancelled
fi

ACTION="$(choose "You need an App Store Connect API key: the .p8 file, its Key ID, and your Issuer ID.\n\nApp Store Connect ▸ Users and Access ▸ Integrations ▸ Team Keys ▸ +, role Developer or above. The .p8 downloads once and cannot be downloaded again — keep it somewhere safe.\n\nHave all three ready?" \
  "Cancel" "Open App Store Connect" "Choose .p8…")" || cancelled

if [[ "$ACTION" == "Open App Store Connect" ]]; then
  open "$PORTAL"
  choose "Download the .p8 and copy the Key ID and Issuer ID, then run this again." "OK" >/dev/null || true
  exit 0
fi

KEY_PATH="$(osascript -e 'POSIX path of (choose file with prompt "Choose your App Store Connect API key (.p8)" of type {"p8", "public.data"})' 2>/dev/null)" || cancelled
[[ -f "$KEY_PATH" ]] || { echo "No such file: $KEY_PATH" >&2; exit 1; }

# The file Apple hands you is named AuthKey_<KEYID>.p8, so offer the Key ID
# rather than asking for something already on screen.
SUGGESTED="$(basename "$KEY_PATH" | sed -n 's/^AuthKey_\([A-Za-z0-9]*\)\.p8$/\1/p')"
KEY_ID="$(ask "Key ID — 10 characters, listed beside the key in App Store Connect:" "$SUGGESTED")" || cancelled
[[ -n "$KEY_ID" ]] || cancelled

ISSUER="$(ask "Issuer ID — the UUID at the top of the Team Keys page:")" || cancelled
[[ -n "$ISSUER" ]] || cancelled

echo "▸ storing profile \"$PROFILE\" in the login Keychain…" >&2
xcrun notarytool store-credentials "$PROFILE" \
  --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER"

echo "▸ asking Apple whether the credentials actually work…" >&2
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  choose "Profile \\\"$PROFILE\\\" is stored and Apple accepted it.\n\ntools/release-mac.sh can now do a full notarized release." "OK" >/dev/null || true
  echo "✓ \"$PROFILE\" stored and verified." >&2
else
  choose "Stored, but Apple rejected the credentials.\n\nUsually a mistyped Key ID or Issuer ID, or a key whose role is below Developer." "OK" >/dev/null || true
  echo "✗ \"$PROFILE\" stored but Apple rejected it — re-run and re-check the Key ID and Issuer ID." >&2
  exit 1
fi
