# Full-duplex voice processing and interruption

**Status:** Accepted (2026-09-08); supersedes the half-duplex decision of 2026-06-05.
The historical filename is retained for existing links.

## Decision

Keep microphone capture active during model playback on macOS and iOS. Use
AVAudioEngine voice processing for acoustic echo cancellation, with the audio
session in `playAndRecord` / `voiceChat` mode on iOS. Convert the processed mono
capture to the provider's sample rate; mix 24 kHz model playback into the native
output format. Remove the old half-duplex microphone gate.

The earlier `-10875` failure was reproduced on the built-in Mac audio route.
Connecting the 24 kHz player caused AVAudioEngine to automatically change the
output client format from 48 kHz to 44.1 kHz while input remained at 48 kHz.
Save the output format immediately after enabling voice processing, before
connecting the player, and explicitly connect the mixer with that saved format.
Use a mono tap at the negotiated input sample rate; do not downmix the
multi-channel voice-processing format exposed by the input node.

## Interruption semantics

- Provider speech-start events immediately flush playback. Generation tokens
  keep discarded buffer callbacks from draining a newer response's queue.
- Qwen and OpenAI events belonging to an interrupted response are discarded by
  response ID, including late audio, transcript and tool events.
- OpenAI receives `conversation.item.truncate` with item identity and completed
  playback frames. A partially played buffer is conservatively excluded. The
  most recent item remains available during gaps between arriving buffers.
- Gemini interruption preserves user input transcription but discards interrupted
  model output. Provider tool cancellation prevents queued execution and
  suppresses late receipts; it cannot undo an action already performed.
- Qwen has no client truncation implementation in the current adapter. Gemini
  manages interrupted conversation history on the server.
- The displayed speaking phase ends only after response completion and playback
  drain; capture remains active in every phase of a running audio engine.

## Validation and limits

On 2026-09-08, an isolated native probe using the actual Mac RealtimeAudioIO
started with voice processing, captured during queued playback, flushed that
playback, drained replacement playback, and stopped twice successfully. No
microphone audio was stored or uploaded. Scoped coordinator regressions and
both platform builds are checked separately.

This does not establish acoustic quality, actual provider speech interruption,
iPhone hardware behavior, Bluetooth/route changes, or installation acceptance.
Those require actual calls on the relevant devices. A voice-processing startup
failure remains an explicit call failure; it does not silently enable untreated
full-duplex speaker audio.
