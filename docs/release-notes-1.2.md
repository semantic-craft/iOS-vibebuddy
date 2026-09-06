# vibebuddy 1.2 — More reliable notifications and Watch glance

This release focuses on the capabilities already implemented and verified in the Mac, iPhone and Watch companions.

- More reliable notification delivery: one banner per cue, clearer reasons for suppressed delivery, quota controls, and missed-wait tracking.
- Approval and question banners support their available actions and request Time Sensitive delivery when the final delivery policy permits it. System notification and Focus settings still apply.
- Identified phones keep one push registration when their token changes, with current preferences. Historical registrations without a device identity are not automatically removed when their ownership cannot be determined.
- Companion presentation across Mac, iPhone and Watch, including the followed-task Watch complication, exact completion-read synchronization, and recovery across disconnection or source changes.
- Clear local guidance when Codex hooks are disabled, without rewriting the user's Codex configuration.

The existing Claude Code, Codex and Grok integrations retain their individual capability limits. Phone actions require a reachable paired Mac. Existing new-task dispatch applies to supported Claude Code and Codex configurations; it is not a general remote terminal.

Watch question answering, dictation, supplemental instructions and new-task creation are not included. Cursor support, public zero-configuration closed-app push, new haptic mappings and voice-limit redial remain future work. Closed-app notifications require the owner's configured APNs sender; no project-operated relay or bundled project signing credential is introduced.

## Distribution

The Mac release is Developer-ID signed and notarized, with a signed Sparkle update feed. iPhone and Watch remain self-install companions requiring appropriate signing and device provisioning; this is not an App Store release or a universally installable IPA.

The release acceptance record is kept with the frozen candidate and its artifact hashes. The owner replaced the previous week-long observation gate with a continuous half-hour acceptance window for this release; that window is not a claim of long-term reliability or completion of every historical device matrix.
