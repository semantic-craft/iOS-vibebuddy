# Gemini text summary integration — local verification

Source baseline: `d7cb0532172e03519587f013f76fd20a6755182f`. Local uncommitted change, isolated checkout.

The existing Mac completion-summary provider picker now offers Gemini. Its editable
model defaults to `gemini-3.8-flash`; the existing Generate sample action and normal
completion-summary/content-presentation services use Google's public
OpenAI-compatible endpoint with low reasoning effort. Credentials use the existing
provider Keychain UI (`gemini.apiKey`); no key was entered or changed in this task.
Voice and cloud speech synthesis remain unavailable for Gemini. If read-aloud
follows the summary provider, select a supported read-aloud provider explicitly. Switching the summary
picker back restores another configured provider; no automatic cross-vendor fallback
is introduced. Antigravity monitor/allowances are not inference API credentials.

## Evidence

- Kit compiled; 8 purpose-selection/migration tests passed.
- Mac package compiled; 19 CompletionSummaryTests passed, including synthetic
  preference load → launch cleanup → provider request → service result/usage →
  duplicate suppression. Live provider tests skipped by default.
- Full native Mac app Debug build succeeded with signing disabled, including
  settings and voice consumers. Candidate: `/tmp/vibe-gemini-derived/Build/Products/Debug/VibeBuddyMacApp.app`.
- `git diff --check` passed. SwiftPM's known GUI-pin pruning/origin-hash change
  was inspected and Package.resolved restored; dependency versions were not changed.
- Local evidence directory:
  `/Users/xianweizhang/Documents/Codex/2026-10-04/task-5/gemini-vibebuddy-evidence/`.

## Remaining acceptance

No native app launch, installed-app replacement, iPhone build, or actual-agent
completion delivery was performed. A later bounded real API service test passed
as recorded below. Compilation and synthetic tests
do not establish live provider latency, account access, or UI end-to-end acceptance.
The parent owns credential inheritance and remaining real verification.

A bounded live test is available, with an already-authorized GEMINI_API_KEY inherited
in the environment (do not put its value in a shell command):

```sh
VIBEBUDDY_GEMINI_E2E=1 CLANG_MODULE_CACHE_PATH=/tmp/vibe-gemini-clang swift test --disable-sandbox --package-path VibeBuddyMac --filter realGeminiSummaryService
```

This sends one synthetic record, uses the real summary service and its 12-second
deadline, never reads Keychain or writes preferences, and logs no credential value.
No commit, push, PR, install, or release occurred.

## Subsequent real service test

The realGeminiSummaryService opt-in test passed in 2.177 seconds: one synthetic
record, one Google API request, production service result and usage validation.
The test did not print usage quantities; token totals and monetary cost are unknown.
No personal task content was sent.

The user-level common source is `~/.env` (1Password FIFO), selected by
`~/.config/direnv/lib/helios-secrets.sh`. VibeBuddy's existing `.envrc` selects
DASHSCOPE_API_KEY, DEEPSEEK_API_KEY and DOUBAO_TTS_API_KEY, not GEMINI_API_KEY.
A transient shell selected only GEMINI_API_KEY via that loader under the task's
API-use authorization; no credential or project configuration was persisted.
The coordinator's subsequent clarification restricts future runs to project
whitelists. The runner had already finished at the stop check. No additional
requests were made. Further normal project inheritance needs an authorized
GEMINI_API_KEY addition to the existing `use secrets` line; not applied here.

## Local Antigravity transport experiment

Gemini now has an explicit connection picker: Local Antigravity CLI or Google API.
New Gemini selections default to local; an explicitly saved API selection stays API. Local fixes the
model to `gemini-3.8-flash-low` and bypasses API-key gates for completion notices,
content presentation, and Settings Generate sample. Failures never switch to API.
The adapter accepts text only; this is not a claim about the CLI's other capabilities.

`AntigravityTextRunner.swift` is reusable Foundation/Darwin transport code. It starts
only the signed-in user's `~/.local/bin/agy`, via arguments without a shell, in a
fresh temporary directory with a no-tools agent definition. Only HOME/PATH are
inherited. No API secret is passed or extracted. Prompts contain only the caller's
explicit text and travel as a process argument (not a credential). The CLI may keep
its own conversation history under its normal account. VibeBuddy removes the
temporary workspace and does not log prompt/output bodies.

Retained stdout is capped at 128 KiB; stderr is drained without retention. Pipes are
nonblocking, child exit never waits for descendants' EOF, and timeout/cancellation
kills only the owned child PID. The generic bound is at most 30 seconds; notification
summary service keeps its existing 12-second age deadline and concurrency limit.
All resulting prose passes existing summary/presentation validation.

Verification: 28 synthetic tests across GeminiCLITests, CompletionSummaryTests and
CompletionSummaryPreferencesTests passed, including timeout, flood, cancellation,
parent exit with inherited descendant pipes, key bypass, no API fallback, new-selection local default with explicit API preservation,
and cancellation of one coalesced waiter without disrupting another. Cancelled
shared outcomes are not cached. Generation identities prevent new callers joining
a cancelled worker still unwinding; active-worker capacity includes that worker
until termination, and stale completion cannot overwrite a replacement. Switching local→API refreshes key-presence metadata.
The one opt-in `realLocalGeminiSummaryService` test passed in **9.175 seconds**,
using one synthetic record through the actual product service and signed-in agy.
The native Mac app rebuild succeeded. Logs are `gemini-cli-mac.log`,
`gemini-cli-live.log`, and `gemini-cli-final-app.log` in the evidence directory above.

Re-run only when another paid/allowance-consuming probe is needed:

```sh
VIBEBUDDY_AGY_E2E=1 CLANG_MODULE_CACHE_PATH=/tmp/vibe-gemini-clang swift test --disable-sandbox --package-path VibeBuddyMac --filter realLocalGeminiSummaryService
```

No resident service, production model policy, or installed settings were changed.

The parent reports existing API credential inheritance is now configured; this
worker did not provision or persist keys. Regular app API calls continue to use
the existing Keychain provider slot; isolated E2E uses its existing environment
lookup. This worker ran only the local CLI live test after the transport change.
Remaining acceptance is native settings interaction and actual notification/phone
flow on the installed app, plus Anamra orb integration owned by its task. Neither
the unsigned build nor the service E2E establishes those outcomes.

## Offline shutdown review and follow-up (2026-10-04)

Standards review: no confirmed new violation. The saved 91-sample main-thread
trace shows `MenuBarModel.startServer` → `MainActor.run` → `NSApplication.terminate`
→ AppKit's termination event loop. That code, the delegate's `.terminateLater`
and both Cursor/Grok shutdown implementations are unchanged from baseline.
The hung QA binary was built at 04:17:17, before the agy adapter; its symbol table
contains neither `GeminiCLI` nor `AntigravityTextRunner`. No UI model request was
initiated. These facts do not establish a Gemini cause, nor independently prove
a baseline defect. The exact pending async cleanup remains unobserved.

Spec review: owned-child cancellation and shared-subscriber isolation are
implemented. Added deterministic cancellation-after-startup proof: wait for the
fixture child PID, cancel, verify that PID disappears and a separate control
process survives. Gemini CLI suite: 9 tests passed (real-model test opt-in).
Existing Cursor/Grok ACP cleanup and content-presentation suites: 58 tests in
5 suites passed. No app launched, no new model requests. These do not validate
AppKit termination or delivery of a real notification.

The isolated QA PID was force-terminated only after separate explicit cleanup
authorization and fresh executable/bundle/start-time checks; no network sockets,
child processes or user documents were present. Its restart stays paused for
the Monitor installation window. Normal quit remains an independent defect
candidate, not an accepted product flow. An in-flight agy request is bounded
by its timeout; immediate cancellation on app quit is not yet proven and must
be verified before lifecycle acceptance.

## Offline completion delivery integration (2026-10-04)

`GeminiCompletionDeliveryTests` now drives production `SessionStore` from native
Codex hook lifecycle events and frozen result evidence through the Gemini summary
service/adapter, the persisted completion-notice decision, `SoundPolicy`,
`NotificationCoordinator`, and the durable per-recipient claim. Model subprocess output and the OS
notification sink are deterministic substitutes; configuration/time are controlled
and the app-level handler is mirrored after its OS eligibility gates. The handler
uses the same frozen-result extraction as `MenuBarModel.generateCompletionNotice`,
but does not exercise that method's focus/quiet/receiver or post-generation
configuration checks. No real model request was made.

The coordinator gained one injectable `CompletionNoticeAttempts` dependency;
production still defaults to `.shared`. Tests use disposable, uniquely named
UserDefaults suites, removed afterward, so production claims are not touched.
Sandboxed `synchronize()` returned false and correctly prevented posting. The
same integration tests passed with filesystem access for those isolated suites.

Proved across success/new-turn/expiry cases:

- Pending wording does not notify; successful Gemini text earns one local attempt.
- A repeated completion event makes only one model request. Repeated snapshots
  and a second coordinator sharing persisted claims cannot schedule it twice.
- A new turn cancels the old notice; a late model result cannot notify it.
- Expiry discards late AI wording. Existing policy still permits **one plain
  completion notice** for a valid settled result; this is not total silence.
- Restoring the lifecycle/notice ledgers and observing the recovered backlog
  neither regenerates historical Gemini text nor schedules a new local attempt.

`GeminiCompletionDeliveryTests`, `CompletionNoticeIntegrationTests`, and
`NotificationCoordinatorTests`: **19 tests in 3 suites passed**, including the
new parameterized test's 3 cases. Log: `gemini-product-integration.log` in the
existing evidence directory. MacCore and its test/CLI consumers compiled during
this run; the previous unsigned GUI artifact predates only this default-preserving
injection seam and these tests.

Remaining OS boundary: actual `UNUserNotificationCenter` authorization/posting,
AppKit focus/quiet gating, the private menu-model polling closure in a running app,
phone APNs/CloudKit delivery/receipt, and app-quit lifecycle behavior were not
exercised here. The spy's `.scheduled` response is an attempted schedule, not proof
of delivered/heard notification. No GUI launch, installed-app replacement, model
call, primary-checkout change, commit, or release occurred in this follow-up.
