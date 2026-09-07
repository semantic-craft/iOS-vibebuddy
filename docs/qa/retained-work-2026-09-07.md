# Retained work integration — 2026-09-07

Baseline: `ebb645a` (after the 1.3.5 release and device installation record).

## Disposition

- PR #64: integrate explicit answer, steer and continue intents, exact wait/turn guards and request deduplication through the current phone action and receipt flow. Preserve uncertain delivery and prevent automatic retries.
- PR #65: integrate restoration of ordinary cues after Mac presence expires. Preserve current completion delivery; do not infer live presence from a phone's read-only card.
- PR #73: integrate bounded recent dialogue in session details. Exclude reasoning/analysis and tool results, preserve completion fields when adding transcript paths, and isolate phone caches across pairing/source changes.
- PR #69: retain only time-limited Smart Stack relevance in the current followed-task widget. Its older three-count widgets are superseded by the current followed-task and quota widgets.
- Metis unique planning changes: merge the existing commits containing next-work discovery and Mac App Store planning pointers. No new store implementation is implied.
- Metis stash: duplicate obsolete agent instructions, archived in a recovery bundle and dropped.
- Sixteen additional Metis mirror branches: already absorbed, superseded or historical. Preserve the historical Cursor research separately and remove obsolete refs after checking their backup bundle.

Detailed historical branch audit and extracted research are local under `.scratch/retained-work-audit/`; Metis recovery bundles are under `.scratch/sync-recovery-20260907/`.

## Validation

- Independent code review completed; integration findings were fixed, including completion-field loss, analysis visibility, pairing isolation and ambiguous receipt presentation.
- Final shared-kit run: 330 tests in 45 suites passed.
- Final targeted Mac run: 22 tests in 5 suites passed (presence/steer, recent output, server answer and hook event areas).
- iOS DashboardStore: 11 tests passed, including delayed output across pairing changes. The final subsequent UI adjustment only gives an existing receipt priority over an offline label.
- iOS/Watch and Mac app builds passed during integration. Final iOS build is checked again after receipt presentation cleanup.
- Real daemon smoke: ran the newly built daemon in an isolated instance, authenticated to its snapshot and recent-output endpoints, and read five visible entries from a real current Codex Desktop rollout. No command, acknowledgement or notification was sent to a user's task/device. The first attempted port collided with another local service; the successful run used a free port.

These checks do not constitute physical iPhone/Watch acceptance of the newly integrated features. Installed/public Mac 1.3.5 and installed iOS/Watch build 15 predate this integration; this record does not claim a new release or replacement of those apps.
