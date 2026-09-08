# Qwen preview ownership checks

`reader-main.swift` links the actual QwenReadAloud, SettingsTestCoordinator and
existing Kit package objects. Compile like the service probe in README.md, with
QwenReadAloud.swift added to the source list. Ten checks cover Settings preview
cancellation, preserved queued automatic work, global stop, the voice gate and
stopping while automatic validation is suspended.

Synthesis is injected as a gate that returns empty data after cancellation.
Automatic validation returns false, or credential lookup is injected as nil.
No real credentials, network, microphone or audio output are used.

`reader-window-main.swift` additionally links AppWindows, AppActivationPolicy,
SettingsTestFeedback and SettingsTestLifecycle. Wrap its executable in a macOS
bundle with a unique random CFBundleIdentifier before running, to isolate frame
preferences. Use an allocated visible-window slot only. It operates on its own
Dashboard and Settings windows and exits 2 on a focus change. Closing Settings
must invalidate the active preview while retaining automatic queued work; late
data cannot restore success, and reopening the retained window is unverified.

A fixture pass does not verify production Settings field/paste interactions,
provider access, audio hardware, a real Buddy conversation, or human hearing.
