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

## Continuous GPT-Live audio (2026-09-11)

The response-based completion/truncation rules above apply to Realtime providers.
GPT-Live has no corresponding speech-start, output-audio-done or item-truncation
events. It manages interruption within its continuous stream. Its transcript
fragments are captions, never authoritative completed turns or action-cancellation
signals. A backend tool or the explicit local whole-call hangup command described in ADR-0008 ends the call.

Continuous output includes silence. Both platform players retain every buffer
to preserve timing and separately count buffers with audible signal. Live's
speaking phase follows that playback count, not backend completion, transcript
arrival or queued silence. The signal threshold changes only the display and
never gates capture, drops audio, or approves an action. Existing generation
tokens still prevent flushed callbacks from draining a newer playback queue.

## Release voice processing on hangup (2026-09-11)

Installed Mac/AirPods acceptance found background audio remained ducked after
`end_voice_call` and an idle UI; quitting the app restored it. Stop rendering,
then explicitly disable voice processing on the stopped input node (which also
disables the output node). Do this before iOS audio-session deactivation. Release
the call coordinator during teardown rather than relying on another event.
The system voice processing remains enabled throughout an active call.

A retained-object native probe confirms capture stops and voice processing is
false after repeated stop. Actual post-call volume recovery remains a manual
acceptance condition; engine state alone does not establish hearing quality.

## Hardware recovery and audio-session ownership (2026-09-12)

Hardware unavailability immediately changes the visible call state to recovering.
It does not cancel a tool turn. macOS observes both engine configuration changes
and the default CoreAudio input/output devices. iOS observes route changes, engine
configuration, system interruption and media-services reset; interruption holds
capture stopped until an allowed resume. A disallowed resume ends the call.
Media-services reset discards orphaned native objects and ends the current call;
[Apple QA1749](https://developer.apple.com/library/archive/qa/qa1749/_index.html)
requires another user action before activation, so the UI asks the user to restart.

Control recovery on the main actor and rebuild on the dedicated serial hardware
queue after leaving the notification callback, with a fresh
engine, player, converter and tap. Validate both native input and output formats
and retain the saved-output-format VPIO workaround. Invalidate capture and playback
generations before rebuilding or stopping. Every queued capture send checks its
originating generation again on the provider actor. Recovery never reconnects or
replays network actions. Keep AEC during normal duplex playback; this temporary
hardware gate does not reintroduce half-duplex microphone gating.

Recovery has at most three attempts (200 ms between attempts) and an eight-second
window, including the two-second provider pause/resume acknowledgement or delivery
limits. Notifications do not reset an existing budget. Synchronous native calls
cannot be forcefully timed out; check the deadline and call identity after they
return. Exhaustion ends the call explicitly; stop always invalidates recovery.

On iOS, activation uses `setActive(true)` without deactivation-only options.
After stopping and disabling voice processing, deactivate with
`notifyOthersOnDeactivation`. Release failures are visible and logged. A
process-wide ownership token on the static hardware queue retains a failed deactivation obligation across
calls, including a replacement call whose activation fails. Bounded cleanup retries share the static iOS hardware queue with activation and
cannot deactivate a newer owner's session. Voice-processing release
failure also remains visible; it is not silently treated as successful cleanup.

These changes require separate real-device Bluetooth, interruption and post-call
volume acceptance. Control-flow fault injection and builds do not establish that
physical acceptance.
