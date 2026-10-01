# MiniMax Token Plan: summary generation and read-aloud

Research note, 2026-10-01. Checked against current MiniMax documentation and its official CLI source. API facts below are documentation-grounded. The subsequent live comparison and final choice are recorded in [the benchmark](minimax-benchmark-2026-10-01.md); subjective listening remains pending.

## Endpoints and subscription scope

| Operation | China | International |
| --- | --- | --- |
| Synchronous speech | `https://api.minimax.cn/v1/t2a_v2` | `https://api.minimax.io/v1/t2a_v2` |
| Chat completion | `https://api.minimax.cn/v1/chat/completions` | `https://api.minimax.io/v1/chat/completions` |

The current China documentation redirects the former `platform.minimaxi.com` pages to `platform.minimax.cn`. The official CLI uses the same regional base URLs and appends `/v1/t2a_v2`; there is no separate Token Plan speech path. Sources: [China speech API](https://platform.minimax.cn/docs/api-reference/speech-t2a-http), [international speech API](https://platform.minimax.io/docs/api-reference/speech-t2a-http), [CLI regional configuration](https://github.com/MiniMax-AI/cli/blob/main/src/config/schema.ts), [CLI endpoints](https://github.com/MiniMax-AI/cli/blob/main/src/client/endpoints.ts).

Requests use `Authorization: Bearer <key>` and JSON. Use the subscription Key from Token Plan, not a pay-as-you-go key: the credentials and billing resources are separate. Covered text, image and speech share quota; purchased credits may cover excess usage. Token Plan pricing explicitly excludes voice design and rapid voice cloning. Its CLI guide demonstrates Speech 2.8 synthesis. Sources: [quickstart](https://platform.minimax.cn/docs/token-plan/quickstart), [FAQ](https://platform.minimax.cn/docs/token-plan/faq), [pricing](https://platform.minimax.cn/docs/guides/pricing-token-plan), [CLI guide](https://platform.minimax.cn/docs/token-plan/minimax-cli).

## Fast summary generation

The initial documentation-only candidate was `MiniMax-M3` with `thinking: {"type":"disabled"}`. The live benchmark superseded it with `MiniMax-M3.1-Flash-Preview` using adaptive thinking and `reasoning_effort=low`, which was faster and more faithful on the tested samples. `reasoning_split: true` keeps any reasoning out of final answer content. The response's `choices[0].message.content` is the summary. Actual latency still requires measurement. [Chat Completions API](https://platform.minimax.cn/docs/api-reference/text-chat-openai)

The model IDs `MiniMax-M3.1-Flash-Preview`, `MiniMax-M3`, and `MiniMax-M2.7-highspeed` all exist. Their thinking behavior differs:

| Model | Thinking control | Consequence |
| --- | --- | --- |
| `MiniMax-M3` | `thinking.type=disabled` skips thinking | Suitable initial choice for brief summaries |
| `MiniMax-M3.1-Flash-Preview` | Always thinks; `disabled` or effort `none` returns HTTP 400 | `reasoning_effort=low` reduces work; default is `max` |
| M2.x, including `MiniMax-M2.7-highspeed` | `disabled` is accepted but ignored | Highspeed does not remove reasoning latency |

The API overview calls M3.1 Flash Preview an M Plan / MiniMax Code model. The more specific [Token Plan migration notice](https://platform.minimax.cn/docs/m-plan/token-plan-notice) explicitly includes M3.1 Flash Preview for existing Token Plan subscribers; legacy Token Plan access is supported. These are exact documented IDs, not `M3.1` or an invented `M3-highspeed`. Sources: [model guide, thinking and availability](https://platform.minimax.cn/docs/guides/text-generation), [API model enum and thinking fields](https://platform.minimax.cn/docs/api-reference/text-chat-openai), [international API](https://platform.minimax.io/docs/api-reference/text-chat-openai).

## Speech request and response

`speech-2.8-turbo` is an official model ID and a reasonable speed-oriented starting choice; `speech-2.8-hd` is another current option. Both are listed alongside 2.6, 02 and 01 HD/Turbo models. A short summary can use non-streaming synthesis with `output_format: "hex"`, `voice_setting.voice_id`, and MP3 audio. Text must be under 10,000 characters; above 3,000 the docs recommend streaming. The successful envelope has `base_resp.status_code=0`, `data.audio` containing hex bytes, and `data.status=2`. Reject null/missing audio and malformed hex. HTTP success alone does not establish synthesis success. [Speech API](https://platform.minimax.cn/docs/api-reference/speech-t2a-http)

Handle service codes: `1001` timeout, `1002` rate limit, `1004` authentication failure, `1039` TPM limit, `1042` excessive invalid characters, and `2013` invalid parameters. The general catalog also lists `1008` insufficient balance and `2049` invalid key. Preserve useful status text without logging request authorization. Sources: [speech response schema](https://platform.minimax.cn/docs/api-reference/speech-t2a-http), [error catalog](https://platform.minimax.cn/docs/api-reference/errorcode).

## Voice styles

Ordinary synthesis has no documented free-text `instruction` field. `voice_setting` provides `voice_id`, speed (0.5–2), pitch (integer −12–12), volume, and a finite emotion selection. The API normally infers emotion from the spoken wording. The `whisper` and `fluent` options are limited to Speech 2.6; the docs explicitly exclude `whisper` for 2.8. Do not send a style description as spoken text. [Speech API, voice_setting schema](https://platform.minimax.cn/docs/api-reference/speech-t2a-http)

Recommended candidates for the existing Chinese `VoiceStyle` cases:

| Style | Official voice ID | Suggested initial controls |
| --- | --- | --- |
| Standard | User-selected voice | Preserve selected rate; no forced emotion |
| Serious | `Chinese (Mandarin)_News_Anchor` (新闻女声) | `calm`, ordinary pitch/rate |
| Coquettish | `diadia_xuemei` (嗲嗲学妹) | `happy`, modest pitch lift if audition supports it |
| Sultry | `wumei_yujie` (妩媚御姐) | Slightly slower/lower; do not use `whisper` with 2.8 |

The names/IDs are official; their fit and parameter values require listening. Keep the existing persona wording from `VoiceStyle.wording`, since that is a separate input to speech. English candidates documented in the same catalog include `English_Graceful_Lady`, `Sweet_Girl`, and `English_Whispering_girl`; their names alone do not establish equal persona quality. [System voice catalog](https://platform.minimax.cn/docs/faq/system-voice-id)

Natural-language voice descriptions belong to the separate `/v1/voice_design` operation: it accepts `prompt` and `preview_text`, then returns a reusable `voice_id` and trial audio. It is not a per-utterance style instruction and is excluded from current Token Plan coverage. Existing system voices are sufficient for this integration. Sources: [voice design API](https://platform.minimax.cn/docs/api-reference/voice-design-design), [Token Plan exclusions](https://platform.minimax.cn/docs/guides/pricing-token-plan).

## Local implementation and verification

Implemented the China endpoint in VibeBuddy. Summary generation now defaults to M3.1 Flash Preview
with low reasoning; read-aloud defaults to Speech 2.8 Turbo. Chinese styles
select the system voices above. Standard keeps the chosen voice and speed 1 /
pitch 0; serious uses 1 / 0, coquettish 1.05 / +1, sultry 0.9 / −1. No forced
emotion is sent: the voice and styled wording carry the persona.

Verified on 2026-10-01: Mac Debug build, iOS Simulator Debug build, Kit speech /
provider / style checks and Mac summary checks. An isolated Mac app with bundle
`com.vibebuddy.e2e.minimax-tts` displayed MiniMax for summaries and read-aloud,
M3 as the text default, and all four styles. Selecting Coquettish activated the
existing own-voice behavior. The installed app was not replaced.

Initially no MiniMax credential was found at either project's documented Keychain slot
or in `MINIMAX_API_KEY`. The user subsequently provided a temporary key through a
native secure input. All candidate APIs and audio decoding passed the benchmark;
physical playback and listener acceptance remain unverified. `MiniMaxLiveTests` supplies an
opt-in summary-to-audio check using `MINIMAX_E2E=1`, `MINIMAX_API_KEY`, a real
agent result file in `MINIMAX_SOURCE`, and an output directory in `MINIMAX_OUTPUT`.
It records elapsed times and playable audio for all four styles, but does not
claim an actual playback/listening check.

## Official-contract corrections after benchmark

- Thinking uses the generation token budget; too small a cap can return `length`
  with no answer. M3.1 and other thinking models now use 4096 tokens for both
  notice and speech, matching the tested reasoning allowance. M3 alone disables
  thinking and keeps 512/2400. These are ceilings, not requested output lengths:
  the existing 180-character notice and 900-character speech checks still apply.
  Notice keeps its 12-second deadline; speech keeps 30 seconds. Source:
  [OpenAI SDK parameter and thinking tables](https://platform.minimax.cn/docs/api-reference/text-openai-api).
- The benchmark no longer overrides production request parameters. Its original
  30-request results remain historical evidence, not a claim that the original
  512-token notification configuration was live-tested.
- Non-streaming TTS must return `data.status=2`; incomplete/missing status is
  rejected before playback. Documented quota/balance codes 2056/1008 now have an
  actionable quota message rather than a generic connection/configuration error.
  Text code 1039 means a token limit, while the speech schema describes TPM;
  they are mapped at their respective API boundaries. Sources:
  [speech response](https://platform.minimax.cn/docs/api-reference/speech-t2a-http),
  [error catalog](https://platform.minimax.cn/docs/api-reference/errorcode).
- A style's actual voice now appears in the disabled voice picker on Mac/iPhone;
  returning to Standard restores the user's separately stored voice selection.
  No unsupported `whisper` or free-form instruction is sent to Speech 2.8.

Verification of these corrections: targeted Kit tests and Mac summary tests
passed; Mac Debug and iOS Simulator builds passed. In the isolated Mac app,
Coquettish displayed 嗲嗲学妹, and returning to Standard restored 新闻女声.
A fresh live acceptance on 2026-10-01 used a temporary native secure-input
credential and the corrected production requests, without benchmark overrides.
`MiniMaxLiveTests.summaryAndStyledSpeech` passed in 19.956 seconds using an actual
agent result describing these changes. The short notice completed in 2.021 seconds
within its 12-second deadline. All four styles generated summaries and complete,
decodable MP3 audio with the configured voice IDs:

| Style | Summary seconds | TTS seconds | Combined seconds | Audio seconds |
| --- | ---: | ---: | ---: | ---: |
| Standard | 1.923 | 1.518 | 3.441 | 17.676 |
| Serious | 3.607 | 2.091 | 5.698 | 27.216 |
| Coquettish | 2.967 | 1.845 | 4.812 | 15.372 |
| Sultry | 2.421 | 1.547 | 3.968 | 16.452 |

The text model was `MiniMax-M3.1-Flash-Preview` with adaptive/low reasoning;
TTS used `speech-2.8-turbo`. This single acceptance run confirms the corrected
request/response and audio-decoding path; it is not a latency distribution or
physical playback/listener acceptance. The installed app was not replaced.
Local evidence: `.scratch/minimax-live-corrected/run-1.log`,
`.scratch/minimax-live-corrected/results/timing.json`, and the four style MP3 files.
The temporary credential was not persisted, and its wrapper process exited.
The earlier 30-call benchmark remains the model-selection comparison.
