# Provider-agnostic realtime voice over WebSocket

**Status:** Accepted (2026-06-05); amended 2026-09-05 — the Qwen provider now
targets Qwen-Audio 3.0 Realtime (`qwen-audio-3.0-realtime-plus`) instead of
Qwen3.5-Omni Realtime, with an optional Bailian workspace-specific endpoint;
amended 2026-09-23 — a provider's per-connection limit ends the call as
`ended(providerLimit)` with a one-tap redial (below); amended 2026-09-25 —
Gemini Live removed (below). Gemini mentions above that date are historical.

The voice companion talks to four cloud realtime vendors (Qwen-Audio
Realtime, OpenAI GPT-Live or Realtime, Gemini Live, Doubao Realtime). We put them all behind one `RealtimeVoiceProvider`
actor protocol that emits a shared `RealtimeVoiceEvent` stream, so the audio
capture/playback and the UI never know which provider is active. Adding a
provider is one Kit file; swapping is a Settings picker.

## Considered options

- **Per-provider bespoke UI/flow** — rejected: triples the UI + audio work and
  couples the app to each vendor's quirks.
- **OpenAI-compatible-only** (Qwen mirrors OpenAI's schema) — rejected: Gemini's
  Live API uses a different schema (`setup` / `realtimeInput` / `serverContent`),
  so a clean abstraction over events was needed anyway.

## Doubao and independent purposes (2026-09-08)

Doubao Realtime 3.0 uses model `1.2.6.1`, the recommended Vivi voice, and one
realtime API key stored under `doubao.realtime.apiKey`. Custom model/voice values
remain until the user explicitly restores defaults. No AppID or token field is
required. Session readiness requires `session.created`; close waits for
`session.closed` or a bounded one-second cleanup timeout.

Voice conversation and completion summaries select providers independently.
Before the first voice-provider change, a valid previous shared text-provider
choice is retained for summaries. Missing, invalid or realtime-only choices
remain unconfigured; they never silently become Qwen. Summary requests use only
the summary provider's credential and text model. Mac read-aloud remains a
separate Qwen TTS capability. Settings checks use isolated sessions without
microphone capture, task context or tools; configuration confirmation is not
conversation or audio acceptance.

## Read-aloud joins the abstraction (2026-09-09)

The 2026-09-08 section above said Mac read-aloud "remains a separate Qwen TTS
capability". It no longer does: the same decision now covers text-to-speech.
Synthesis sits behind a `SpeechSynthesizer` protocol with one conformance per
vendor, and the read-aloud player obtains audio through the protocol without
knowing which vendor is speaking. Adding a vendor is one Kit file plus one case,
exactly as for realtime.

Read aloud is therefore a third purpose provider alongside voice conversation
and completion summaries, and requires TTS rather than text generation. Its
default is **follow the summary provider**; pinning a provider stops it
following. Following inherits the summary provider's unconfigured state too —
read-aloud reports that it is waiting for a summary provider rather than
falling back to Qwen, matching how an absent or invalid summary choice is
handled. Model and voice are stored per provider; the Qwen-only keys are
migrated once at launch and removed.

## OpenAI Live and a separate task backend (2026-09-11)

OpenAI conversation defaults to `gpt-live-1`, through its own Kit adapter and
`/v1/live/sessions` WebSocket contract. A deliberately configured Realtime model
still uses the active Realtime API. The factory never retries a failed Live call
against Realtime. Existing nonblank model/voice choices remain explicit choices.

Live uses Responses delegation, which fits our existing structured-tool/app-
execution boundary. The default task backend is `gpt-5.6-luna`, editable separately
in both platform Settings with the same OpenAI credential. Live receives a short
conversation/delegation prompt; detailed task rules belong to the backend. Status
queries read the current selected voice scope, excluding stale summaries from
running tasks. A task's summary is data, not a current wait or an instruction.

Completion summaries remain independent stateless text requests. OpenAI's text
default is `gpt-5.6-luna` with reasoning disabled for the bounded notification;
Live/Realtime model IDs are rejected on this path. Notifications prioritize the
meaningful outcome or blocker and supported next action within the existing
two-sentence/180-character contract. Voice time and backend requests have separate
billing; no new server, credentials, consent defaults or installation are implied.

## A text-only summary provider (2026-09-13)

DeepSeek joins as the first vendor with **no voice side**: it serves completion
summaries only. `VoiceProvider` therefore stops meaning "a realtime backend" and
means "a vendor we talk to", with two capability flags deciding what each one may
be picked for — `supportsCompletionSummaries` (already excluded Doubao) and the
new `supportsVoice` (excludes DeepSeek). Voice conversation and read-aloud offer
`voiceProviders`; summaries offer `summaryProviders`; accounts list every vendor,
because a key belongs to the vendor rather than to a feature.

`SpeechSynthesis.support` is no longer total: it returns `nil` for a text-only
vendor rather than handing back a synthesizer that cannot work. Read-aloud gains a
third state for following a summary provider that cannot speak — it says so and
waits for a pin, the same refusal to invent a vendor that keeps it from falling
back to Qwen when summaries are unconfigured. A stored conversation or read-aloud
choice naming a text-only vendor is treated as no choice.

The summary request is OpenAI-compatible chat completions, so it shares Qwen's
request shape, response decoding and usage mapping. It differs in three ways: a
single endpoint (`https://api.deepseek.com/chat/completions` — Qwen's region
switch and workspace ID do not apply), the recommended model `deepseek-flash`
(DeepSeek-V4.1-Flash), and `"thinking": {"type": "disabled"}`, because DeepSeek
defaults to thinking at high effort and a 180-character spoken notification has
no use for a reasoning budget. No new consent default, credential path or server
is implied: it is one more BYO key in the Keychain (ADR-0002).

## Global content styles (2026-09-15)

Content preferences are independent of voice/persona preferences and of the text
provider. Notice, speech, history and recap share a prompt builder and provider
transport, while notices retain their 12-second, 180-character delivery contract.
Explicit speech and recap requests have a separate bounded generation cache and
resolve original evidence by exact source and round. They do not mutate notice
claims, consent defaults or reading markers. Paired phones use the source Mac's
content preference and generation service; no new cloud or credential store is
introduced. Custom instructions control expression within shared evidence rules.

The two-second capture deadline remains a notification constraint. A successful,
turn-identified terminal event may separately retain bounded text for manual
reading, even when observed later. It is invalidated by a new turn, failure or
retirement, and cannot replace an already retained result. This does not revive
an expired notification. Recap copies use the same verified round evidence.
(Recap was removed on every device on 2026-09-26; see ADR-0028's amendment.)

## Provider-limit ending and redial (2026-09-23)

Realtime providers cap one connection. Reaching the cap used to surface as
a generic connection failure, or not at all. It is now its own event,
`RealtimeVoiceEvent.providerLimitReached`, and the coordinator's terminal phase
`VoiceCallPhase.ended(.providerLimit)`: audio stops, the session closes once,
late provider events are ignored and no error is shown. iPhone (voice strip,
voice page) and Mac (menu-bar panel, Glance, Voice and reading panel, dashboard
sidebar) show "Call ended: <provider> reached its per-call time limit" with a
**Redial** button. A microphone frame that fails to send as the server closes
at the cap is left to the receive loop, which classifies the close. Redial is an ordinary new call with the same Settings — no transcript,
tool state or provider session carries over. Continuing a call across the cap
(Gemini session resumption, context carry-over) is deliberately not built.

Only an explicit provider signal maps to the limit; a network drop, an auth,
quota or rate-limit error, or a server fault stays `failed`. The rules
(`ProviderLimitSignal`, verified 2026-09-23):

| Provider | Documented cap | Signal mapped to the limit |
| --- | --- | --- |
| OpenAI GPT-Live | not stated | `session.closed` with `reason: "expired"` |
| OpenAI Realtime | 60 minutes | `error.code == "session_expired"` (code seen in field reports; the docs list no code) |
| Gemini Live | ~10-minute connection, 15-minute audio session | the socket ending after a `goAway` message |
| Qwen-Audio 3.0 Realtime | 120 minutes on the shared realtime endpoint (Omni docs; the Qwen-Audio page states none) | a server close frame (not 1011) once the connection is ≥ 119 minutes old — Qwen sends no limit event |
| Doubao Realtime | none documented | not mapped; its idle release (10 minutes silent) stays a failure |

## Gemini removed (2026-09-25)

The owner removed Gemini from every purpose — conversation (Gemini Live),
completion summaries and read-aloud — and cancelled its D-1 provider-limit
check. `VoiceProvider.gemini`, `GeminiRealtimeSession`,
`GeminiSpeechSynthesizer`, the Gemini voice catalog, its summary request
shape and its `goAway` limit rule are deleted; the provider-limit table's
Gemini row above is historical. `ended(providerLimit)` and Redial stay: the
OpenAI and Qwen rules still map to them.

A stored Gemini choice falls back per purpose at launch
(`VoiceSettings.removeRetiredGeminiSettings`), never to another vendor on the
user's behalf: conversation returns to the default provider with the voice
companion switched off (the consent was given for Gemini), summaries become
not configured, read-aloud stops pinning and follows summaries (the iPhone's
read-aloud reads system speech), and Gemini's model, voice and style values
and its Keychain key are removed.

The agent source string `gemini` (`AgentKind.fromSource` → `.antigravity`) is
the Antigravity coding agent, not this provider, and is unaffected.

## MiniMax text and read-aloud (2026-10-01)

MiniMax joins for summaries and TTS, without a realtime adapter. The historical
shared voice capability now applies to realtime only; `readAloudProviders` and
read-aloud settings use `SpeechSynthesis.support` instead. Following MiniMax
summaries therefore resolves to MiniMax TTS, while conversation never selects it.

The China endpoint accepts a user-supplied Token Plan key stored in the existing
Keychain scheme. Defaults are `MiniMax-M3.1-Flash-Preview` with low reasoning and
`speech-2.8-turbo`; no fallback changes the key, region or billing route. M3.1
cannot disable thinking, but the owner's live benchmark found low reasoning
faster and more faithful than M3 with thinking disabled. An explicitly selected
M3 still disables thinking.
Chinese announcer styles select documented system voices plus modest speed/pitch
adjustments and the existing persona wording. Synthesis has no free-form style
instruction, and Speech 2.8 does not support whisper emotion. Voice design and
cloning are outside this integration. Model latency and persona quality require
live acceptance; the model defaults now have a bounded local benchmark (below).

Sources and limits: `docs/agents/minimax-tts-research.md`; measured selection:
`docs/agents/minimax-benchmark-2026-10-01.md`.

## Gemini reintroduced by purpose (2026-10-04)

The owner approved restoring summaries, read-aloud and conversation ([PRD](../planning/backlog/gemini-provider-suite/PRD.md)), superseding the removal above. This first slice enables summaries; the speech pickers wait for their adapters.

Swift uses the device-local key directly (ADR-0002). Google GenAI SDK v2.24.0 is the pinned protocol reference; no Firebase or Python/JS runtime is added. Summaries use independent Interactions with `store=false`, no tools/history, and only final `model_output` text; existing limits, cancellation and evidence checks apply.

Both platforms stop retirement cleanup; explicit preferences remain, deleted keys cannot be recovered and features are not newly enabled. The initial summary default is `gemini-3.5-flash-lite`, pending comparison with `gemini-3.8-flash`; custom choices remain and invalid models fail without fallback. The agent source alias `gemini` still denotes Antigravity.
