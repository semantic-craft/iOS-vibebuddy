# MiniMax summary and TTS benchmark — 2026-10-01

## Decision

Use `MiniMax-M3.1-Flash-Preview` with `thinking.type=adaptive`, `reasoning_effort=low`, and `reasoning_split=true` for summaries. Keep `speech-2.8-turbo` for read-aloud. The user-provided key successfully called all six candidate models. This supersedes the initial documentation-only M3 recommendation.

## Method and scope

- Summary: two synthetic Chinese agent-result samples, each run twice per model (four requests/model). One describes a completed fix with unverified device acceptance and no commit/release; the other describes a three-step plan blocked before real testing by missing credentials.
- Same production `.speech` prompt and output decoder, non-streaming responses, sequential requests with rotated model order. M3 disabled thinking; M3.1 used adaptive/low; M2.7-highspeed used adaptive. All used a 30-second timeout and a 4096-token output cap to avoid truncating reasoning. At benchmark time production used 2400 tokens for speech and 512 for notifications, which were not separately benchmarked. The subsequent official-contract review aligned thinking models with this 4096-token cap and removed the benchmark override. Non-thinking M3 retains 512/2400.
- TTS: serious, coquettish and sultry preview lines, twice/model (six requests/model). Same voice IDs, speed/pitch controls, MP3 format and production adapter. Measures complete audio generation, not streaming first-audio latency.
- No warm-up was discarded. This is a small, single-account, single-network measurement, not a load test. Audio was decoded by AVAudioPlayer; successful decoding does not establish subjective voice quality or physical playback.
- The temporary secure input passed the credential in memory. It was not saved to the repository, a log, or Keychain.

## Timings

| Purpose | Model | Successful requests | Median seconds | Min–max seconds |
| --- | --- | ---: | ---: | ---: |
| summary | `MiniMax-M3` | 4/4 | 6.578 | 3.001–16.195 |
| summary | `MiniMax-M3.1-Flash-Preview` | 4/4 | 1.800 | 1.318–4.447 |
| summary | `MiniMax-M2.7-highspeed` | 4/4 | 8.948 | 5.411–16.760 |
| speech | `speech-2.8-turbo` | 6/6 | 0.962 | 0.849–1.126 |
| speech | `speech-2.8-hd` | 6/6 | 1.151 | 0.860–1.324 |
| speech | `speech-2.6-turbo` | 6/6 | 1.012 | 0.855–1.188 |

## Summary content review

M3.1 retained the supplied result, verification limitations and blocked-step status in all four outputs, without inventing a user action. M3 had one clear grounding violation: it added “需要你确认密钥怎么提供，或是否用现有资源先开始，拿到结果后再比较。” The source did not ask for either decision or propose alternative resources. M2.7 preserved the key facts, but was slower; one output also added a next-step sentence rather than stopping at the recorded state.

M3.1 was about 73% faster than M3 and 80% faster than M2.7-highspeed by these medians. Speech 2.8 Turbo was only about 4.9% faster than 2.6 Turbo and 16.4% faster than 2.8 HD; those small TTS differences should not be treated as a universal ranking. It remains the speed-oriented default because all tested styles generated valid audio and HD showed no measured latency benefit.

## Reproduction and evidence

`VibeBuddyMac/Tests/VibeBuddyMacCoreTests/MiniMaxBenchmarkTests.swift` contains the bounded opt-in comparison. Run `swift test --package-path VibeBuddyMac --filter MiniMaxBenchmarkTests` with `MINIMAX_BENCHMARK=1`, a securely supplied `MINIMAX_API_KEY`, and `MINIMAX_OUTPUT`. A normal test run skips paid calls.

Local raw results and first-round audio: `.scratch/minimax-benchmark/results/`. Benchmark: 30/30 requests succeeded in approximately 100 seconds. Raw outputs are summarized above; no claim of real installed-app playback or subjective listening acceptance is made.
