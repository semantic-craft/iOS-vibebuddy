# Provider-agnostic realtime voice over WebSocket

**Status:** Accepted (2026-06-05); amended 2026-09-05 — the Qwen provider now
targets Qwen-Audio 3.0 Realtime (`qwen-audio-3.0-realtime-plus`) instead of
Qwen3.5-Omni Realtime, with an optional Bailian workspace-specific endpoint.

The voice companion talks to four cloud realtime APIs (Qwen
Realtime, OpenAI Realtime, Gemini Live, Doubao Realtime). We put them all behind one `RealtimeVoiceProvider`
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

Official contracts and validation are recorded in [GPT-Live assessment](../gpt-live-1.md).

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
