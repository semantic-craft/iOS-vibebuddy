# Half-duplex mic gating instead of hardware echo cancellation

Enabling AVAudioEngine voice-processing (`setVoiceProcessingEnabled`, which would
give hardware echo cancellation) failed to initialize the engine on macOS
(`-10875`, "client-side input and output formats do not match" under the realtime
sample rates). Instead we run **half-duplex**: while the model is speaking we
stop forwarding mic audio, then re-open the mic when playback drains.

## Consequences

- No barge-in (you can't interrupt the model mid-sentence) — acceptable for v1.
- Reliable, no feedback loop, no format constraints. Headphones still help.
- Revisit if WebRTC (which bundles AEC) is adopted later.
