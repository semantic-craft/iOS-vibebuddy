# Shared Kit realtime sessions; platform-specific audio I/O and UI

**Status:** Accepted (2026-06-05)

The realtime WebSocket sessions (`QwenRealtimeSession`, `OpenAIRealtimeSession`,
`GeminiRealtimeSession`, `DoubaoRealtimeSession`) live in `VibeBuddyKit` as pure Foundation /
`URLSessionWebSocketTask` and are platform-agnostic. The audio I/O
(`RealtimeAudioIO`) and the UI are written per platform — macOS omits
`AVAudioSession`; iOS requires it. So iOS reuses the Kit sessions unchanged and
only adds its own audio I/O + UI, keeping the wire/protocol logic in one place.

## Availability contract (2026-09-12)

The shared coordinator consumes `VoiceAudioAvailability` independently of
provider events. During recovering/interrupted hardware states it drops playback
and cannot publish listening or speaking; a terminal failure stops the call.
Platform controllers bind callbacks to the current call, show recovery explicitly,
and retain cleanup diagnostics after teardown.

Provider actors own their input discontinuity protocol. Doubao clears partial PCM
and obsolete queued audio before ordered mute/unmute. GPT-Live waits for the
matching `client_event_id` mute/unmute acknowledgement and suppresses obsolete
sender audio. Qwen, OpenAI Realtime and Gemini have no local capture frame buffer;
the actor-isolated validity check rejects old capture work before socket enqueue.
Already submitted audio is not described as retracted. Wire sample rates and
PCM16 formats remain unchanged.
