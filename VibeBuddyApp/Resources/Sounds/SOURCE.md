VibeBuddy sound pack source
===========================

Generated with MiniMax Token Plan CLI (`mmx 1.0.16`) using `music generate`
with model `music-2.5+`, `--instrumental`, `--format wav`, and
`--sample-rate 44100`.

The generated WAV files were post-processed locally with `ffmpeg` and
`afconvert`: silence trim, short crop, fade in/out, high-pass/low-pass,
limiter, mono 44.1 kHz, then CAF/IMA4 conversion.

No third-party audio samples were used.

Files
-----

- `pair_success.caf`
- `needs_answer.caf`
- `needs_approval.caf`
- `agent_done.caf`
- `agent_stuck.caf`
- `long_wait_nudge.caf`

Prompts
-------

pair_success:
A tiny app notification sound effect, not music. Pairing success for a coding companion. Soft glass ping plus warm muted wood tick, sparse, clean, no vocals, no speech, no drums, no bass, no melody, no alarm, no harsh highs, low distraction.

needs_answer:
A tiny app notification sound effect, not music. A coding agent is waiting for a short answer. Two gentle ascending soft glass tones, warm and polite, no vocals, no speech, no drums, no bass, no melody, no alarm, no harsh highs, low distraction while programming.

needs_approval:
A tiny app notification sound effect, not music. Permission approval required for a coding agent. A clear but soft double tap, muted wood plus small glass accent, no vocals, no speech, no drums, no bass, no melody, no alarm, no harsh highs, calm and precise.

agent_done:
A tiny app notification sound effect, not music. Coding task completed. Soft resolved chime, warm low mallet then tiny bright tail, no vocals, no speech, no drums, no bass, no melody, no celebration, no harsh highs, calm focus.

agent_stuck:
A tiny app notification sound effect, not music. Coding agent is stuck or failed. Low soft wooden knock, dull warm texture, no alarm, no vocals, no speech, no drums, no bass, no melody, no harsh highs, informative but not stressful.

long_wait_nudge:
A tiny app notification sound effect, not music. Gentle reminder after a long wait. Very quiet breath-like soft glass pulse, sparse and almost ambient, no vocals, no speech, no drums, no bass, no melody, no alarm, no harsh highs, low distraction.

Sounding rules
--------------

Only *state boundaries* ring; process noise (starting work, plain refreshes)
stays silent. The full decision logic lives in `VibeBuddyKit/SoundPolicy.swift`
and is unit-tested in `SoundPolicyTests.swift`.

- needs_answer / needs_approval — on a fresh transition into needsResponse;
  fired once, then debounced 90s against re-entry of the same session.
- agent_done — only when a task actually ran (> 30s) AND the app isn't in front
  (you can already see a completion you're watching).
- agent_stuck — when a completion's summary reads like a failure (heuristic:
  fail / crash / abort / fatal / timeout / …); rings regardless of runtime.
- long_wait_nudge — one gentle reminder once a wait sits unanswered past 3 min.
- pair_success — once when a new phone pairs (Mac) / a fresh pairing is saved (iOS).

Quiet / Focus mode keeps only approvals; everything else falls silent (the
visual surfaces — banner, Live Activity — remain). The first snapshot after
connecting never rings its backlog. There is no per-sound volume: notification
sounds play at the system notification volume.
