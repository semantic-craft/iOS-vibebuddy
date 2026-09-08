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
