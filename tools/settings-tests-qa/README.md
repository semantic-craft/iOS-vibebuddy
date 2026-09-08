# Settings test lifecycle probes

Run from the repository root on macOS. No probe reads production preferences,
Keychain, usage cookies, microphone or session history, or calls a provider.

## Coordinator

```sh
swiftc -swift-version 6 -parse-as-library VibeBuddyMacApp/Sources/SettingsTestCoordinator.swift tools/settings-tests-qa/main.swift -o /tmp/settings-tests-qa
/tmp/settings-tests-qa
```

15 checks exercise cancellation, timeout, cleanup barriers and late responses.

## Actual summary service's nested worker

Build the Mac app first. Compile `service-main.swift` with the coordinator,
`-I <DerivedData>/Build/Products/Debug`, and the package objects in that directory.
Pass each `Build/Intermediates.noindex/GeneratedModuleMaps/*.modulemap` with
`-Xcc -fmodule-map-file=<path>`, plus include paths for `_AtomicsShims`, `CSystem`
and `CNIOWindows` under the corresponding SourcePackages checkouts.

The injected lookup deliberately blocks a real internal service worker, then
returns nil. There is no usable credential or HTTP request. Five checks verify
that generate returns promptly on cancellation while Settings retains its slot,
idle waits return when the worker exits, and invalid input does not hang.

## Native retained window fixture

Compile `window-main.swift` with AppActivationPolicy, AppWindows,
SettingsTestCoordinator, SettingsTestFeedback and SettingsTestLifecycle using
`swiftc -swift-version 6 -parse-as-library`. Place the executable in a fixture app
bundle with a unique random CFBundleIdentifier to isolate frame preferences.
Run only during an allocated visible-window slot. The executable checks its own
key window before closing it and exits 2 if focus changes. It does not activate
production Settings or exercise actual providers/Buddy. Exit 2 is incomplete
acceptance, not a passing run; consult the logged PASS lines.
