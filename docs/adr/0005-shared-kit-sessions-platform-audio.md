# Shared Kit realtime sessions; platform-specific audio I/O and UI

The realtime WebSocket sessions (`QwenRealtimeSession`, `OpenAIRealtimeSession`,
`GeminiRealtimeSession`) live in `VibeBuddyKit` as pure Foundation /
`URLSessionWebSocketTask` and are platform-agnostic. The audio I/O
(`RealtimeAudioIO`) and the UI are written per platform — macOS omits
`AVAudioSession`; iOS requires it. So iOS reuses the Kit sessions unchanged and
only adds its own audio I/O + UI, keeping the wire/protocol logic in one place.
