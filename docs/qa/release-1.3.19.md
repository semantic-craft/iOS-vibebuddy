# Mac 1.3.19 acceptance

Candidate: Mac build 31. No mobile changes.

- Release build passed for the final content-sized layout before the version bump.
- Independent review found no blocking issues: geometry measurements affect only position, the camera offset cancels unequal wing widths, and content remains bounded by fixed font sizes and the 99+ visual count cap.
- Installed Developer ID candidate on the physical Mac. System geometry reports a 185 x 33 pt housing. Computer Use captured a real Codex approval card and its return to compact state with one Requires input count. Compact width was approximately 240 pt and height 33 pt, with the camera gap centered and no strip underneath.
- Production health returned ok. Existing agent data remained visible after restart.
- Rapid voice/count transitions, a second Mac model and physical monitor hotplug were not exercised. The capture establishes the observed steady state, not every transition.

Evidence: `.scratch/notch-collapsed-height/build-content-width.log`, `content-width-check.md`, and `.scratch/release-1.3.19/` for packaging and publication. The small view-only change uses build, review and live UI evidence rather than implementation-mirroring tests.

Mobile remains TestFlight build 46 with its separate outstanding production acceptance gates.
