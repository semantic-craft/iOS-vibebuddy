# VibeBuddy 1.3.8

Mac direct distribution: 1.3.8 (15). iPhone and Apple Watch: 1.3.8 (19).

This update brings clearer model settings, Doubao realtime voice, and improvements to iPhone and Apple Watch task interaction.

- Separate voice, summary and read-aloud configuration, with service connection checks.
- Doubao realtime voice support and improved audio startup, streaming and interruption handling.
- Watch quick answers, task navigation, confirmed stop actions and stronger attention haptics.
- Fix Watch notification Reply not opening text input; restore the custom notification interface.
- Improve phone connection recovery with WebSocket heartbeat detection and bound Watch action receipt waits without automatically resending actions.
- Improve task state reconciliation, completion notifications and cross-device delivery.

## Validation and limitations

Physical tests passed for Qwen and Doubao conversation interruption, Watch quick answers, Cancel, touch/Double Tap Stop, notification Reply delivery, background notifications and Live Activity updates. Connection recovery was exercised with the actual iOS simulator app and real companion service under controlled traffic loss.

Doubao sustained-call stability remains under investigation after a connection-too-slow event. Physical cold-launch/network recovery, Watch approval actions and audio-device switching have not completed acceptance. This release does not represent those scenarios as verified.

After connecting to an already-running Codex turn, Stop may be offered but refused until the current turn is observed. If a Stop request times out, its eventual completion may produce an error cue even though the task stopped; the initial action remains explicitly unconfirmed. These recovery-edge cases are tracked for a subsequent update.

The macOS DMG is the direct-distribution edition. iPhone/Watch App Store availability depends on Apple's separate processing and review; the Mac App Store edition is not included.
