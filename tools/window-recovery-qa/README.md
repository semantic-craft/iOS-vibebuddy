# Mac window recovery checks

Run the AppKit lifecycle probe from the repository root on a logged-in Mac:

```sh
swiftc -swift-version 6 VibeBuddyMacApp/Sources/AppActivationPolicy.swift \
  VibeBuddyMacApp/Sources/AppWindows.swift tools/window-recovery-qa/main.swift \
  -o /tmp/vibebuddy-window-qa
/tmp/vibebuddy-window-qa
```

The probe uses test content and checks retained window identity, Dock policy,
minimization recovery, and preserving a keyable floating panel's frame.

## Close Settings while recording a shortcut

Exercise the actual app or a separately identified demo bundle:

1. Open Dashboard, then Settings > General.
2. Click Record next to Open Dashboard. Confirm the control says "Press a combo…".
3. Close Settings with the red window close button without entering a combination.
   Do not use Cmd+W: the recorder intentionally captures a valid combination.
4. In Dashboard, press Cmd+F and type a search term. The term must appear and filter sessions.
5. Press Cmd+, to reopen Settings. The button must say Record, not Cancel, and the original shortcut must be unchanged.

This catches a local key monitor surviving `NSWindow.close()` when the hosting
controller is retained and SwiftUI does not run `onDisappear`.
