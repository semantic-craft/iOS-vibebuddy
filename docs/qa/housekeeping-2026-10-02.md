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
were removed, accounting for 19.60 GiB of allocated file space before deletion.
This is an allocated-size estimate, not a measurement of APFS physical free-space
change. Evidence logs/results and published DMGs were moved to the primary
checkout without creating archive copies. Relative .scratch/ios-parity/,
.scratch/ios-parity-e2e/ and .scratch/release-1.3.41/ paths now refer to that checkout.
Obsolete one-time edit helpers and source-baseline copies were removed.

The current Grok release worktree and its caches are removed after independent
review, merge and synchronization. Final verification and additional allocated
space are recorded below when completed.

## Verification

No product code was changed by cleanup. The integrated Grok feature retains the
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
