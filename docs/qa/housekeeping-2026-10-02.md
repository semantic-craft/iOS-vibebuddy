# Project housekeeping — 2026-10-02

## Scope and retained work

The owner authorized verification, commits, pushes, PR merge, removal of
confirmed unused resources and archiving completed/superseded project chats.
No extra release was requested. The already-authorized iOS 1.3.34 (69) App Store
submission completed before housekeeping; it is waiting for Apple review.

The primary checkout had 43 changed tracked files and 23 non-tooling untracked
files. Comparison against origin/main and recorded feature commits established
that these were older Cloudflare/MiniMax copies, completed planning copies or
composite Grok edits already integrated into the release branch. The older
provider read path would undo the reviewed loadForUse cancellation fix.
Superseded copies were removed; local skill links and OpenCode configuration
were preserved and excluded locally from Git status.

The original eight Grok commits on local main were preserved as parents of
b4b2ea8a. Its tree exactly matches 6a9a7a49: history integration introduced no
product changes and does not rewrite existing history.

Unfinished work remains in the backlog: real Grok terminal reload/activity and
phone visual acceptance, iOS physical audio/VoiceOver and populated native
Codex details, settings minimum-window/device/service acceptance, and WEB-01
planning. Existing ADRs, research, source transcripts, credentials, configuration
and the installed production app are retained. Parent Grok/settings tickets now
identify completed implementation and the actual remaining acceptance scope.

## Cleanup

Three idle, clean worktrees were removed after ancestor checks proved their
branches merged into origin/main: ios-companion-parity, minimax-language-release
and the detached minimax-release-pages checkout at origin/gh-pages.
Local and remote merged feature branches were removed; gh-pages was advanced
by fast-forward and the local dist/appcast.xml synchronized from that published
branch. Published tags and update files remain unchanged.

41 regenerable build/cache directories in the primary and two merged worktrees
were removed (19.60 GiB), followed by eight unused directories in the Grok
worktree (7.34 GiB): **26.94 GiB** of allocated file space before deletion.
This is an allocated-size estimate, not a measurement of APFS physical free-space
change. Evidence logs/results and published DMGs were moved to the primary
checkout without creating archive copies. Relative .scratch/ios-parity/,
.scratch/ios-parity-e2e/ and .scratch/release-1.3.41/ paths now refer to that checkout.
Obsolete one-time edit helpers and source-baseline copies were removed.

The final Grok worktree is retained only through independent review and merge;
its submitted-build archive and necessary evidence move to the primary checkout
before managed-worktree removal. Builds regenerated for the final regression
checks are removed after those checks. Final Git/worktree/runtime results are
recorded in `.scratch/cleanup-20261002/final-verification.json`; removal and move
manifests remain beside it in the primary checkout.

## Verification

Cleanup itself does not alter behavior. Independent review of the retained
Grok work found and corrected three state problems: healthy idle phones showed
reload guidance without a session, failed Mac setup still showed reload guidance,
and manual hook operations dropped intent/error-only state changes. The phone
also displays both connected and waiting counts. These source changes follow
the immutable App Store build 69 (source 425d5d40); no replacement build,
installation, upload or release was performed during housekeeping.

The manual stale-error regression failed before the fix and passed afterwards.
**51 focused Mac tests** and **3 iOS Grok tests** passed, with no skips or failures;
Mac Debug builds passed including the final copy correction. An isolated Mac
app on :18783 used one actual live Grok registry entry in disposable state.
A deliberately injected setup error was visible in the discovery card; its
Agent integration link opened the matching settings, and Retry cleared the
error, configured hooks and displayed waiting/reload guidance. No synthetic
task was created. Clearing the disposable registry produced healthy idle status.
The isolated app and simulator run were stopped and disposable state removed.
Simulator UI was unavailable to CUA; XCTest card rendering and guidance checks
passed, but live phone visual acceptance remains pending.

Read-only independent Grok Build review used `grok-4.7-build-fast`, `xhigh`,
session `01a0fabb-3ed9-7a32-a4b1-3250999689f4`. Initial verdict: MERGE WITH FIXES.
Re-review of fix commit 03aec4a9: all four items FIXED, final verdict **MERGE**,
no blocking regression. Its non-blocking copy nit was also corrected: an error
card says reporting is not configured only when configured is false. Review,
regression logs and xcresult are retained in `.scratch/grok-release/`; Mac UI
screenshots are in the existing `_shared-work/iOS-vibebuddy/` evidence directory.

The integrated Grok feature also retains the
68 focused Mac tests and 184 iOS tests (five environment-dependent skips, zero
failures), installed Mac HTTP/WebSocket/UI acceptance, and strict distribution
signature/upload evidence. See [mobile](grok-mobile-1.3.34.md),
[Mac](grok-mac-1.3.42.md) and [App Store](grok-ios-1.3.34-distribution.md).
Changed Markdown links and whitespace were checked. Runtime, real-device and
Apple-review limitations remain explicit; housekeeping does not complete them.

Twelve completed or superseded Codex conversations were archived: the MiniMax,
language fix, Cloudflare and language-setting conversations, the settings
coordinator and its seven completed implementation conversations. Their useful
outcomes are present in merged code and the retained acceptance/backlog records.
No other project's conversations or running tasks were changed.
