# 02: Provider-limit call ending and redial

Status: ready-for-agent
Node: D-1
Blocked by: none

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

## Provider-limit research — to be completed during implementation

- Qwen-Audio 3.0 Realtime: source, event/close/refusal behavior, and mapping evidence pending.
- OpenAI Realtime: corresponding source and reason evidence pending.
- Gemini Live: corresponding source and reason evidence pending.

## Execution and delivery

Read `AGENTS.md` → `CONTEXT.md` → `docs/planning/vision-2026-09.md` → this ticket and its references. The node's complete `prompt` in the HTML-exported `docs/planning/roadmap-2026-09.json` remains the execution handoff; do not substitute a summary for it.

Use an isolated `.scratch/worktrees/` checkout from `origin/main`; do not edit production code in the main workspace. Add the Executor line when implementation is actually assigned. Record validation evidence and keep physical acceptance separate; do not mark code completion as `done`. No deployment, release, installed-app changes, physical-device operations, access to secrets, or changes to the daemon on port 9876. PR body starts with the node ID, uses Summary / Validation / Not verified here, and has no signature.
