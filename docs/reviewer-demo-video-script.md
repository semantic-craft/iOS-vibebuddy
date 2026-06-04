# Reviewer Demo Video Script

Use this when recording the App Review demo. The simulator demo video in
`docs/app-store-screenshots/pro-max-demo-reviewer-flow.mp4` is a useful fallback,
but the strongest review package is a real Mac + iPhone pairing recording.

## Shot List

1. Show the Mac app in Finder or `/Applications`, then launch `vibebuddy`.
2. Open the menu-bar popover and expand "Pair a phone".
3. On iPhone, launch `vibebuddy` and scan the QR code. If the camera path is
   inconvenient, open "manual entry" and enter the host/port/token shown by the
   Mac.
4. Start or use a live agent session that reaches a permission prompt.
5. Show the iPhone dashboard updating without manual refresh.
6. Show the approval card: project, command/path/diff, then tap Approve or Deny.
7. Start or use a live `AskUserQuestion` prompt.
8. Show the question card options, tap one option, and show the answer arriving
   in the correct Mac tmux pane.
9. Trigger or show a no-option question, type a manual answer, and show it
   arriving in the same pane.
10. Close the iPhone app or lock the screen, trigger another needsResponse, and
    show notification/Live Activity if APNs is configured.

## Reviewer Notes To Say Or Show

- The iOS app has a built-in demo mode, so App Review can inspect the UI without
  a Mac.
- Normal use is direct iPhone-to-Mac over the local network. There is no cloud
  account and no backend storing session data.
- The phone mirrors approval/question state; command execution stays on the Mac
  and is limited to explicit approval/answer paths.

## Local Demo-Mode Recording Command

The existing simulator demo clip was produced with:

```bash
SIM="3C779304-4CDD-4A13-A46B-1F85E9F9AFC8"
APP="$PWD/VibeBuddyApp/build/Build/Products/Debug-iphonesimulator/VibeBuddyApp.app"
BID="com.vibebuddy.app"
VIDEO="docs/app-store-screenshots/pro-max-demo-reviewer-flow.mp4"

xcrun simctl install "$SIM" "$APP"
SIMCTL_CHILD_VIBEBUDDY_DEMO=1 \
SIMCTL_CHILD_VIBEBUDDY_SKIP_NOTIFICATIONS=1 \
  xcrun simctl launch --terminate-running-process "$SIM" "$BID"
xcrun simctl io "$SIM" recordVideo --codec=h264 --force "$VIDEO"
```
