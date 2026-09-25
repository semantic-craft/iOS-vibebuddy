# 02: Provider-limit call ending and redial

Status: done (code) — Gemini path cancelled by the owner 2026-09-25; the Mac/iPhone notice + Redial rendering is unverified and is checked on a natural long Qwen/OpenAI call
Node: D-1
Blocked by: none
**Executor:** Claude (Opus 5.5) · branch claude/hopeful-colden-c7fe90 · 2026-09-23

## Release placement

On 2026-09-06 the product owner chose to release 1.2 with completed capabilities. This unfinished capability is for a subsequent update and is not required for today's 1.2 release. Creating this ticket does not start implementation.

## Sources

- `docs/planning/roadmap-2026-09.json`: D-1 `spec` and complete `prompt`, exported from the canonical HTML.
- `docs/planning/vision-2026-09.md`: Q17 (end and redial without context), Q11 (existing BYO-key voice).
- `docs/adr/0001-provider-agnostic-realtime-voice.md`: shared provider event boundary.
- `.scratch/realtime-verify/issues/01-verify-openai-gemini-in-app-audio.md`: existing audio round-trip verification remains separate.

No `.scratch/realtime-verify/PRD.md` exists at ticket creation. The canonical D-1 specification and Q17/Q11 supply this ticket's scope; no new PRD or product requirement is introduced.

## What to build

供应商单连接上限到顶时提示「通话结束」，一键重拨，不带上下文。

Scope: `VoiceCallCoordinator` state `ended(providerLimit)` (task text: `ended(reason: providerLimit)`), iPhone and Mac UI, and the corresponding end-reason mapping for Qwen / OpenAI / Gemini.

First verify Qwen-Audio 3.0 Realtime's server behavior at its single-connection limit: whether it closes the connection or refuses further audio. Record official source links and the verified behavior in this ticket before implementing the mapping. Verify the corresponding OpenAI / Gemini reasons and map them to the same state. Do not infer a provider-limit event merely from an unrelated disconnect. This is implementation research within the established scope, not a new product decision.

After reaching the limit, present the ended message and one-tap redial. Redial starts a new call without previous context. Keep the existing BYO-key model.

## Out of scope

**续接状态机。** No continuation state machine or context carry-over.

## Acceptance criteria

The roadmap criterion is unchanged: **Kit 测试覆盖状态机；两端构建。**

- [ ] Kit tests cover the provider-limit ending and redial state behavior.
- [ ] iPhone and Mac builds pass.

## Validation and evidence

Roadmap verification: **Kit 测试。** Use `cd VibeBuddyKit && swift test` and the two app build commands from the node's complete prompt; never pass `-sdk iphonesimulator` to the iOS scheme. Record commands/results and provider-limit research below. Do not claim a real provider audio session has been verified from fixtures or builds. Existing issue 01 audio round-trip acceptance is unchanged.

## Provider-limit research (verified 2026-09-23)

Official pages were read directly on 2026-09-23; field reports are marked as such. Rules live in `VibeBuddyKit/Sources/VibeBuddyKit/ProviderLimitSignal.swift` and the Gemini/Qwen session files.

- **Qwen-Audio 3.0 Realtime.** The [Qwen-Audio realtime page](https://help.aliyun.com/zh/model-studio/fun-audiochat-realtime) states no session or connection duration; its only limit is context (50 turns / 300 s of audio, older history dropped, connection kept). The [Omni-Realtime page](https://help.aliyun.com/zh/model-studio/realtime) for the same `/api-ws/v1/realtime` endpoint says a single session lasts at most 120 minutes, after which the service closes the connection. No error event, close code or reason is documented, and audio is not refused before the close. **Verified behavior: the server closes the connection; nothing announces it.** Mapping (inferred, conservative): a close frame the server sent (`closeCode` not `invalid`/`abnormalClosure`/`internalServerError`) once the connection has lived ≥ 119 minutes since `session.created` → provider limit. An earlier close, a drop without a close frame, HTTP 401/403/404/429 and `error` events stay failures.
- **OpenAI Realtime.** [Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations): the maximum session duration is 60 minutes. The limit arrives as an `error` event with `code: "session_expired"` ("Your session hit the maximum duration of N minutes"); the code comes from field reports (OpenAI community thread 975036, livekit/agents#2341), not the docs. Mapping: `error.code == "session_expired"` → provider limit, then the client closes; the message text is not matched.
- **OpenAI GPT-Live.** [Live conversations](https://developers.openai.com/api/docs/guides/live-conversations): `session.closed` carries `reason`; `expired` means the session reached its duration limit (no value stated). `close_requested`, `content`, `remote_hangup` and `connection_lost` are other endings. Mapping: `session.closed` with `reason: "expired"` while we are not closing → provider limit.
- **Gemini Live.** [Session management](https://ai.google.dev/gemini-api/docs/live-api/session-management): audio-only sessions are limited to 15 minutes without compression, a connection to about 10 minutes; the server sends `goAway` with `timeLeft` before the connection is terminated as ABORTED. Mapping: the socket ending after a `goAway` → provider limit; any close without one is a failure. Field reports on discuss.ai.google.dev say `gemini-3.1-flash-live-preview` sometimes drops at the limit with 1006 and no `goAway`; those calls still read as a connection failure. Session resumption is out of scope.
- **Doubao Realtime.** No session duration documented; `45000003` (10 minutes without interaction) is an idle release and `ExceededConcurrentDurationLimit` is quota. Not mapped.

## Implementation evidence (2026-09-23)

- Kit: `RealtimeVoiceEvent.providerLimitReached`; `VoiceCallPhase.ended(VoiceCallEndReason.providerLimit)` is terminal — audio stops, the session closes once, late events and tool calls are ignored, no `errorText`. `VoiceCallEndReason.notice(provider:)` is localized en + zh-Hans in the Kit table.
- iPhone: the voice strip and voice page show the notice with a **Redial** button; Mac: the menu-bar panel, the expanded Glance and the Voice and reading panel show it with **Redial**, the dashboard sidebar's Voice row shows the notice. Changing the voice provider or language, or turning the companion off, clears the notice.
- At Gemini's and Qwen's cap a microphone frame in flight fails as the server closes; send failures are then left to the receive loop so the limit is not pre-empted by a generic send error. `VoiceChat.redial()` starts an ordinary new call from the current Settings; nothing from the ended call is sent.
- `cd VibeBuddyKit && swift test` (after merging main at 7fbb6b95): 595 Swift Testing tests in 92 suites plus the XCTest suites pass, including `ProviderLimitSignalTests` (per-provider mapping, send failure at the cap) and the new `VoiceCallCoordinatorTests` cases (limit ending, unrelated endings, zh-Hans notice).
- iOS `xcodebuild -scheme VibeBuddyApp -destination 'generic/platform=iOS' -configuration Debug build -quiet CODE_SIGNING_ALLOWED=NO` and Mac `xcodebuild -scheme VibeBuddyMacApp -configuration Debug build -quiet` succeed.
- **Not verified (superseded for Gemini by the 2026-09-24 comment below):** no real call has reached a provider cap (60–120 minutes of billed audio for OpenAI Realtime and Qwen, about 10 minutes for Gemini). Real-call acceptance: hold a Gemini Live call past ~10 minutes and confirm the notice + Redial on iPhone and Mac; the others when a long call happens naturally.

## Execution and delivery

Read `AGENTS.md` → `CONTEXT.md` → `docs/planning/vision-2026-09.md` → this ticket and its references. The node's complete `prompt` in the HTML-exported `docs/planning/roadmap-2026-09.json` remains the execution handoff; do not substitute a summary for it.

Use an isolated `.scratch/worktrees/` checkout from `origin/main`; do not edit production code in the main workspace. Add the Executor line when implementation is actually assigned. Record validation evidence and keep physical acceptance separate; do not mark code completion as `done`. No deployment, release, installed-app changes, physical-device operations, access to secrets, or changes to the daemon on port 9876. PR body starts with the node ID, uses Summary / Validation / Not verified here, and has no signature.

## Comments

- 2026-09-24, real-call acceptance:
  - **Provider limit, Gemini, live API: passed (Kit layer).** A headless harness drove the app's own `GeminiRealtimeSession` + `VoiceCallCoordinator` (Kit at main 9137f92f, `gemini-3.1-flash-live-preview`, 100 ms silence frames, key from `GEMINI_API_KEY`). The server ended the connection at 591.9 s → `providerLimitReached` (the log does not print `goAway`; the session only reports the limit when the socket ends after a `goAway`, `GeminiRealtimeSession.swift` `connectionEndEvent`) → phase `ended(providerLimit)`, `errorText` nil, notice "Call ended: Gemini (Google) reached its per-call time limit. Redial starts a new call without this conversation." Redial opened a fresh session that connected in 0.8 s. This time there was no 1006 drop without `goAway`. Log: `~/Projects/_shared-work/iOS-vibebuddy/acceptance-2026-09-24/04-d1-gemini/harness.log`; harness source in `…/tools/d1harness/`.
  - **Not verified:** the Mac app's own `VoiceChat` handling and the notice and **Redial** button as rendered in the Mac UI. Computer-use access to the installed app was declined in that session, so there is no screenshot. The iPhone path is also unverified: an unsigned simulator build cannot store the key (`-34018`).
- 2026-09-25, Gemini removed: the owner removed the Gemini integration and cancelled the D-1 Gemini test (ADR-0001 § Gemini removed). `GeminiRealtimeSession`, its `goAway` rule and the harness's Gemini path are gone, so the 2026-09-24 evidence above is historical. The iPhone D-1 check is no longer needed; the notice + Redial as rendered on Mac and iPhone stays unverified until a natural long call reaches a cap. `ended(providerLimit)` + Redial remain for OpenAI (GPT-Live / Realtime) and Qwen; their caps (60–120 minutes) are covered by `ProviderLimitSignalTests` only, and a real cap is checked when a long call happens naturally.
