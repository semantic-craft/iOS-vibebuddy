# Provider-agnostic realtime voice over WebSocket

**Status:** Accepted (2026-06-05); amended 2026-09-05 — the Qwen provider now
targets Qwen-Audio 3.0 Realtime (`qwen-audio-3.0-realtime-plus`) instead of
Qwen3.5-Omni Realtime, with an optional Bailian workspace-specific endpoint.

The voice companion talks to three different cloud realtime APIs (Qwen
Realtime, OpenAI Realtime, Gemini Live). We put them all behind one `RealtimeVoiceProvider`
actor protocol that emits a shared `RealtimeVoiceEvent` stream, so the audio
capture/playback and the UI never know which provider is active. Adding a
provider is one Kit file; swapping is a Settings picker.

## Considered options

- **Per-provider bespoke UI/flow** — rejected: triples the UI + audio work and
  couples the app to each vendor's quirks.
- **OpenAI-compatible-only** (Qwen mirrors OpenAI's schema) — rejected: Gemini's
  Live API uses a different schema (`setup` / `realtimeInput` / `serverContent`),
  so a clean abstraction over events was needed anyway.
