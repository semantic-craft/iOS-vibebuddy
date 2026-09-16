# macOS 1.3.22 build 36

## Scope

Build 36 combines the completion recovery and settings work from build 35 with responsive Agent CLI detection, incremental history indexing, responsive history search, Codex fork identity repair, and managed Cursor recovery and native controls. The iOS changes are included in source control but are not an iOS release.

## Existing behavior evidence

- Candidate `ac96da2c`: isolated native Mac acceptance covered distinct parent/fork conversations, search while indexing, appended messages, repeated Agent CLIs navigation, and same-named project selection. The checkout was clean and the recorded source hashes remained unchanged. This was a Debug run, not final Release installation evidence.
- Codex fork repair `004dbb8a`: 29 XCTest and 78 Swift tests, distinct parent/child HTTP reads and pagination, and independent review passed. The existing 2 MiB completion-record limitation remains.
- Cursor work was exercised separately in its worktree: full plan, refusal, restart and same-session continuation, real Read tool output, explicit read acknowledgment, stop, and rejection of stale actions. Integration checks for the final source revision are recorded below.
- The earlier installed build 35 exercised real Desktop completion recovery and saved-key summary generation. Its separate record is retained in `release-1.3.22.md` and is not evidence of a build 36 installation.

## Retained limits

- Cursor's upstream `WritableIterable is closed` error can arrive as ordinary assistant text followed by `end_turn`. The original text is visible; reliable structured failure classification is unavailable. No automatic retry or text-matching failure heuristic was added.
- Automatic read acknowledgment under genuine user-presence conditions and live Cursor IDE Hooks were not accepted. Managed ACP acceptance does not establish IDE integration acceptance.
- Physical iPhone/Watch, production APNs and iOS 17 acceptance remain separate. The last iOS pairing run contains a failed final step. The iOS submission condition has not been met.
- Existing denied macOS notification permission and software playback completion do not establish banner delivery or human listening acceptance.

## Final release checks

The first integrated run passed 14 XCTest cases but failed one of 163 Swift Testing cases: `endingAndCancelCannotResurrectATurn`. An isolated replay and a full replay passed; these did not close the failure. Investigation identified a real actor-reentrancy race: wait cleanup could run after the stop event and reset a completed session to working. Two deterministic regression cases failed on the old implementation. Fix `a7498805` preserves the completed state while clearing stale wait metadata, retaining the existing exact-ID guards. The owner passed 122 focused tests and independent review; final integrated verification follows below.

- Final integrated source: `90e1208f9eaa706e21e726e8ca23112da2697074`. All 945 tracked input hashes remained unchanged through the Release build. Subsequent changes to this report do not change executable inputs.
- Final Mac checks: 14 XCTest cases and 164 Swift Testing cases in 23 suites passed. Shared Kit checks: 15 tests in two suites passed. Agent Hooks installer/retirement checks and four verification-helper tests passed. No timeout or concurrency assertion was relaxed.
- Independent integration and late-cleanup reviews found no blocking issue.
- Release 1.3.22 (36) built successfully. Every bundled Mach-O passed Developer ID, hardened runtime and secure timestamp checks; deep strict signature verification passed.
- App notarization `c2498a27-efa8-4522-b671-ef9810df2856`: Accepted; app stapled.
- DMG notarization `427330ce-4c96-456e-bc9a-ff3d6b028ff6`: Accepted; DMG stapled and validated. Gatekeeper accepted both app and DMG.
- Release executable SHA-256: `f82ffb7d5169da8e5babb188280932f16ad79974534a91d2cdadbd6bce8ec62b`.
- DMG SHA-256: `2d98a694c6088d9fe26be5aeffe7ada45b1592ad8489c5b3b5ff93a9f712f7f8`; 27,814,397 bytes. Sparkle's verifier independently accepted the generated EdDSA signature and enclosure size.

- Final Release-code native smoke passed in an isolated, re-signed copy. All main-executable `__TEXT` section hashes matched the Developer ID original; its executable hash remained unchanged after the run. Real Cursor Read produced one succeeded entry with its original call ID and correct body. Native continuation retained the same session, displayed the full plan, and native Stop removed the plan and left two subsequent snapshots done/userStopped without resurrection. The first menu click did not settle; a refreshed native menu selection completed the action. No HTTP stop replaced the UI action.
- All smoke-test processes and the isolated token/app were cleaned up. The known upstream error text remained visible and is not a clean-provider-run claim.

The release candidate passed the checks above. Publication is a separate operation recorded by the GitHub Release and Sparkle feed. No production app replacement or cross-machine synchronization has been performed.
