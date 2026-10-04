# Gemini 摘要、播报与实时语音官方接入研究

核对日期：2026-10-04。本地代码基线：`5af77f161cd28386beeda8b6c98853811013f43e`。本次仅研究官方文档和源码，不安装依赖、不读取凭据、不调用收费模型、不修改应用或运行配置。型号的 Stable 状态不代表 SDK 的每项能力也已 GA；文档支持也不证明当前账户可调用。

## 推荐组合

建议把 Gemini 做成覆盖三项服务的一组供应商配置，分别选模型。官方已有对应能力，无需把摘要、逐字播报和实时对话塞进同一模型。

| 项目能力 | 推荐起点 | 上游状态与选择理由 |
| --- | --- | --- |
| 完成摘要 | `gemini-3.5-flash-lite` | Stable；针对吞吐、成本和延迟。输出文本，支持结构化输出；不支持音频生成或 Live。复杂摘要可比较 `gemini-3.8-flash` |
| 摘要播报 | `gemini-3.8-flash-lite-tts` | Stable；先满足短文本播报。若实听表现不足，再比较 `gemini-3.8-flash-tts` |
| 实时语音助手 | `gemini-3.8-live` | Stable；官方默认低延迟语音模型，支持工具调用和音频流 |

来源：[当前模型目录](https://ai.google.dev/gemini-api/docs/models)、[3.5 Flash-Lite 型号页](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite)、[3.8 Flash-Lite TTS 型号页](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-lite-tts)、[3.8 Live 型号页](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live)。上述推荐是对项目用途的工程判断，不是中文效果或延迟实测结论。

当前目录把 3.1 Live/TTS 列为旧 Preview，并对 2.5 系列注明新项目访问限制；不要从旧代码或旧示例恢复 2.5 作为默认。不要用会切换实际版本的 `latest` 别名作为验收基线。[模型目录](https://ai.google.dev/gemini-api/docs/models)

## 文本与 TTS：当前接口有重要变化

当前[文本生成指南](https://ai.google.dev/gemini-api/docs/text-generation)使用 `POST https://generativelanguage.googleapis.com/v1beta/interactions`，认证头为 `x-goog-api-key`，输入为 `model`、`input`、可选 `system_instruction` / `generation_config`；SDK 提供 `interaction.output_text`。一次摘要使用独立请求，不需要云端持续对话。[Interactions 概览](https://ai.google.dev/gemini-api/docs/interactions-overview)确认默认存储 interaction，`store=false` 可选择无状态行为；摘要和 TTS 应显式设置它，不串联 `previous_interaction_id`。这不等于对供应商全部数据处理作零保留承诺。原有 generateContent 仍受支持，但新能力以 Interactions 为主。

3.8 TTS 同样走 Interactions。当前[官方 TTS 指南](https://ai.google.dev/gemini-api/docs/speech-generation)要求逐字文本放入 `input`，风格放入 `speech_metadata` annotation，声音放入 `generation_config.speech_config`；`response_format.type` 为 `audio`。不能照搬 2.5 的“把风格混入待朗读文本、`response_modalities` + generateContent”请求。

- 非流式默认返回完整 WAV：24 kHz、单声道、16-bit signed little-endian PCM，解码后可直接保存播放。
- 流式设置 `stream: true`；SSE `step.delta` 的 audio delta 是无文件头 PCM，默认 `audio/l16`、24 kHz、单声道。不能再把每块当独立 WAV，也不能反复补 WAV 头。
- 可显式请求 `audio/l16`、采样率；TTS 只接受文本并输出音频。它适合确定文本播报，Live 适合对话。
- 官方页面要求 Python `google-genai >= 2.25.0` 或 JS `@google/genai >= 2.24.0`，也提供 REST。

以上均来自[当前 TTS 指南的单人、流式、输出格式与限制章节](https://ai.google.dev/gemini-api/docs/speech-generation)。首版应使用预置 voice，把自定义声音等无关能力留在范围外；实际中文发音、标点停顿、英文标识符读法与首包延迟需实听验收。

## Live：需要独立协议适配

[官方概览](https://ai.google.dev/gemini-api/docs/live-api)确认这是有状态 WSS：输入 raw PCM 16-bit little-endian 16 kHz，输出同编码 24 kHz。输入输出转写、打断、工具调用都由 Live 协议提供；它不能代替逐字 TTS 的播报契约。

[WebSocket 指南](https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket)给出 Developer API 端点 `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`。先发送 setup，再发送 `realtimeInput.audio`（Base64 + `audio/pcm;rate=16000`）。产品实现必须把完整带 key 的 URL 从日志与错误展示中排除。云端共享密钥的客户端场景可用短期 token；个人自带 key 模式仍须遵循项目凭据设计，不能为了 SDK 擅自改变配置模型。

3.8 特有规则来自[型号页迁移段](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live)：不要发送 `thinking_level`；proactive audio 永久开启，设置 false 会报错；affective dialog 已移除；响应 modality 选 AUDIO，需要文字则开启 output transcription；中途 `client_content` 的 `turn_complete=true` 会打断正在生成的内容。

工具应映射现有本地命令分发，保留 function call 的 ID，并将结果用 function response 回传。官方[工具指南](https://ai.google.dev/gemini-api/docs/live-api/tools)和 3.8 型号页存在默认行为差异：前者仍说默认同步，后者明确 3.8 默认 `NON_BLOCKING`。实现应显式选择 `BLOCKING` 或 `NON_BLOCKING`，不能依赖默认。回包 scheduling 的枚举拼写也应以固定 SDK/schema 为准，通用指南写 `INTERRUPT`，型号页说明写 `INTERRUPTED`，不可凭文字猜编码。

[会话管理指南](https://ai.google.dev/gemini-api/docs/live-api/session-management)规定：不压缩时纯音频会话 15 分钟，音视频 2 分钟；底层连接约 10 分钟，连接将结束前有 `GoAway`。长会话需 context window compression、session resumption 和恢复 token；token 有效期为会话终止后 2 小时。服务已完成一轮与 WebSocket 已结束是不同事件，接收循环不能混为一谈。

## 官方 SDK：实际源码核验

[官方 SDK 清单](https://ai.google.dev/gemini-api/docs/libraries)主推 Google GenAI SDK；Swift 旧 `generative-ai-swift` 已停止维护，推荐 Firebase AI Logic。[旧 Swift 仓库](https://github.com/google-gemini/deprecated-generative-ai-swift)也明确弃用。官方 SDK 真实存在，但 Swift 路线与直接持有 Gemini key 的通用 GenAI SDK 路线不同。

### JavaScript / TypeScript

核对 [googleapis/js-genai](https://github.com/googleapis/js-genai) main SHA `f6b85db43db2cb88705f60af9c394fee308ac497`。以下不是 README 推测，而是实际代码：

- [src/client.ts](https://github.com/googleapis/js-genai/blob/f6b85db43db2cb88705f60af9c394fee308ac497/src/client.ts)创建 `interactions` 客户端。
- [src/gaos/models/interactions/model.ts](https://github.com/googleapis/js-genai/blob/f6b85db43db2cb88705f60af9c394fee308ac497/src/gaos/models/interactions/model.ts)列出 3.8 Flash/TTS/Flash-Lite TTS；同目录 `speech-annotation.ts` 定义 `speech_metadata`，`audio-response-format.ts` 定义 PCM MIME 与 `sample_rate`，`interaction.ts` 含 `output_audio`。
- [src/gaos/sdk/interactions.ts](https://github.com/googleapis/js-genai/blob/f6b85db43db2cb88705f60af9c394fee308ac497/src/gaos/sdk/interactions.ts)有普通及流式 `create` 重载；[interactions-create.ts](https://github.com/googleapis/js-genai/blob/f6b85db43db2cb88705f60af9c394fee308ac497/src/gaos/funcs/interactions-create.ts)对流式请求设 `Accept: text/event-stream`。
- [src/live.ts](https://github.com/googleapis/js-genai/blob/f6b85db43db2cb88705f60af9c394fee308ac497/src/live.ts)可作为 connect、client content、realtime input、tool response 编解码参考。

现有 SDK 示例有版本滞后：[interactions_multimodal_response_audio.ts](https://github.com/googleapis/js-genai/blob/f6b85db43db2cb88705f60af9c394fee308ac497/sdk-samples/interactions_multimodal_response_audio.ts)仍用 2.5 TTS 和旧 `response_modalities`；[live_client_content.ts](https://github.com/googleapis/js-genai/blob/f6b85db43db2cb88705f60af9c394fee308ac497/sdk-samples/live_client_content.ts)仍用旧模型、TEXT 与 v1alpha token 示例。它们可说明代码组织，不能作为 3.8 请求模板。应以当前型号页、当前协议和固定版本 SDK 类型联合核对。

### Python

核对 [googleapis/python-genai](https://github.com/googleapis/python-genai) main SHA `618f0aa89c7fa61be973fabfa5747fb93a21b1bf`。[client.py](https://github.com/googleapis/python-genai/blob/618f0aa89c7fa61be973fabfa5747fb93a21b1bf/google/genai/client.py)提供同步及异步 Interactions，`interactions.py` 导出生成的 GAOS 类型。当前官方 TTS 指南已有使用此接口的 3.8 示例，适合作为可选独立验证工具，产品无需新增 Python 进程。

[live.py](https://github.com/googleapis/python-genai/blob/618f0aa89c7fa61be973fabfa5747fb93a21b1bf/google/genai/live.py)实现 `send_client_content`、`send_realtime_input`、`send_tool_response` 和 `receive`。Developer API 的工具回包明确验证 ID；`receive` 可在本轮完成时返回，外部需要继续接收下一轮。旧 `send` / `start_stream` 已标 deprecated，部分 docstring 型号也过时。源码仍以 Preview 描述 Live 客户端，这与 3.8 模型的 Stable 标签是两个层次。

### Swift / Firebase AI Logic

主代理核对 [firebase/firebase-ios-sdk](https://github.com/firebase/firebase-ios-sdk) main SHA `030f8b19e14c75f3b52baf9cfd544ad833a4eb16`，证据如下：

- [Package.swift](https://github.com/firebase/firebase-ios-sdk/blob/030f8b19e14c75f3b52baf9cfd544ad833a4eb16/Package.swift)提供 `FirebaseAILogic` product，源码位于 `FirebaseAI/Sources`。
- [FirebaseAI.swift](https://github.com/firebase/firebase-ios-sdk/blob/030f8b19e14c75f3b52baf9cfd544ad833a4eb16/FirebaseAI/Sources/FirebaseAI.swift)要求 FirebaseApp / project ID；[Backend.swift](https://github.com/firebase/firebase-ios-sdk/blob/030f8b19e14c75f3b52baf9cfd544ad833a4eb16/FirebaseAI/Sources/Types/Public/Backend.swift)的 googleAI 也使用 Firebase 代理。
- [APIConfig.swift](https://github.com/firebase/firebase-ios-sdk/blob/030f8b19e14c75f3b52baf9cfd544ad833a4eb16/FirebaseAI/Sources/Types/Internal/APIConfig.swift)生产端点为 `firebasevertexai.googleapis.com`，直接 generativelanguage bypass 是 DEBUG 内部测试路径。
- [LiveSession.swift](https://github.com/firebase/firebase-ios-sdk/blob/030f8b19e14c75f3b52baf9cfd544ad833a4eb16/FirebaseAI/Sources/Types/Public/Live/LiveSession.swift)有 responses、sendAudioRealtime、sendFunctionResponses、sendContent、close、resumeSession。

[Firebase Live 文档](https://firebase.google.com/docs/ai-logic/live-api)仍标 Preview，支持清单列 3.1/2.5，没有证明 3.8 可用；也不能从它存在 LiveSession 推定已覆盖 3.8 TTS Interactions。它更适合由产品统一管理 Firebase 项目、代理和客户端防护的架构。当前项目若保持用户自带 key 和原生 Swift 网络链路，建议以官方 SDK 为协议参考，用 URLSession 实现直接适配；为使用 SDK 引入 Firebase 是架构取舍，不是零成本替换。

## 实施前仍需证实

1. 账户实际可用型号、配额、地区与计费；本次没有真实 API 调用，未做价格或性能承诺。
2. 中文摘要是否准确、短播报是否逐字、Live 转写和工具调用是否可靠；模型列表不能证明这些体验。
3. 固定 SDK release 而非 main 后，3.8 新字段和服务端是否一致；尤其 tool scheduling、音频 MIME、恢复事件。
4. 对照项目 ADR 与当前供应商接口，确定直连 Swift 或 Firebase；随后验证真实数据、打断、错误恢复和长会话。新型号不能绕过现有工具授权边界。

## 对接当前项目的候选方案

用户本轮已明确三项全部覆盖、可独立选择。以下是实现建议，尚未修改产品代码或将技术选型记为已接受 ADR。

现有 [ADR-0001](../adr/0001-provider-agnostic-realtime-voice.md) 于 2026-09-25 记录了全面移除 Gemini；实施本轮目标时须追加重新引入的修订。[ADR-0002](../adr/0002-byo-key-direct-to-provider.md) 保持自带 Key、设备直连、无 VibeBuddy 云服务。[ADR-0004](../adr/0004-half-duplex-mic-gating-not-aec.md) 已于 2026-09-08 改为全双工/AEC，继续复用现有管线（实施核对时纠正按历史文件名作出的误读）。

| 接入位置 | 需要完成的工作 |
| --- | --- |
| [VoiceProvider.swift](../../VibeBuddyKit/Sources/VibeBuddyKit/VoiceProvider.swift) | 增加 Gemini 供应商、三种能力、每用途默认模型、账号入口；沿用一个供应商凭据、三种独立用途设置 |
| [CompletionSummaryHTTP.swift](../../VibeBuddyMac/Sources/VibeBuddyMacCore/CompletionSummaryHTTP.swift) / [Configuration](../../VibeBuddyMac/Sources/VibeBuddyMacCore/CompletionSummaryConfiguration.swift) | 增加 Interactions 请求、正文与用量解析；只读最终文本，排除思考内容；保留通知 12 秒时限、180 字通知及 900 字朗读呈现规则、准确轮次证据和取消检查 |
| [SpeechSynthesis.swift](../../VibeBuddyKit/Sources/VibeBuddyKit/SpeechSynthesis.swift) | 新增 GeminiSpeechSynthesizer，映射 voice 与播报风格；首版完整 WAV 接入现有分段合成和播放器，流式首音优化待有测量依据再做 |
| [RealtimeVoice.swift](../../VibeBuddyKit/Sources/VibeBuddyKit/RealtimeVoice.swift) | 新增 GeminiRealtimeSession，将 setup、音频、转写、轮次完成、工具调用/取消和结束映射为共享事件；在 Mac/iPhone VoiceChat 工厂接入 |
| [VoiceCallCoordinator.swift](../../VibeBuddyKit/Sources/VibeBuddyKit/VoiceCallCoordinator.swift) | 复用现有工具执行和目标核验；建议任务操作显式 BLOCKING，收到应用回执后才确认成功；迟到回包和被取消调用不得重新执行 |
| [KeychainStore.swift](../../VibeBuddyKit/Sources/VibeBuddyKit/KeychainStore.swift) / 两端应用启动 | 移除 removeRetiredGeminiSettings 的持续清理及调用，避免新设置和新 Key 再次被删；已经删除的 Key 不能恢复，未配置用途不自动启用 |
| 两端设置、VoiceCatalog、VoiceStyle、连接检查 | 三个用途都可选择 Gemini，模型/声音分别保存；朗读继续可跟随摘要或单独固定；连接成功、生成音频、真实听到声音分别报告 |

SDK 使用建议：产品保持 Swift URLSession HTTP/WebSocket 适配；官方 Python 或 JS SDK 只用于独立对照探针，固定发布版本后验证协议。Firebase Swift SDK 是可用的官方选择，但采用它会把配置改为 Firebase 项目与代理链路，不能作为当前单 Key 体验的直接替换。也不为复用 JS/Python SDK 给 iPhone 引入额外运行时或中转服务。

长通话继续遵循现有 ADR 的“供应商限制结束 + Redial”：首版不做透明 session resumption。官方支持恢复是能力事实，不是本次必须新增的体验。GoAway 是将结束的预告，应在连接真正结束时结合该信号分类，普通断网和配额错误不伪装为正常到时。

## 实施顺序与验收边界

1. 先接供应商设置和摘要，验证一条真实 Claude/Codex 完成结果能生成正确 Gemini 摘要；验证通知超时、取消和轮次变化不会发布旧结果。
2. 接 TTS 与试听，验证中文/英文短结果、声音和风格、取消及连续播放；保留现有读后状态规则。
3. 接 Live，验证音频往返、转写、查询任务和明确授权的现有任务操作、打断/挂断、工具回执及连接结束。整个目标仍以三项完成为验收，分步只是实施顺序。
4. 添加有价值的协议/迁移回归检查，按 [development](../agents/development.md) 运行受影响的 Kit/Mac 检查与两端构建，再按 [verify-vibebuddy](../agents/skills/verify-vibebuddy/SKILL.md) 做隔离端到端验收。开发凭据显式经项目入口注入；正式用户仍用原有 Keychain 方式。

本次交付仅为研究与候选方案；没有安装 SDK、真实模型调用、应用构建、产品改动、提交、推送或安装。模型与 SDK 文档差异已经记录，账户可用性、延迟、中文质量和设备音频仍未验证。

## Swift 实调用补充（2026-10-04）

3.8 Flash 不接受 `thinking_level=minimal`，真实请求返回 HTTP 400；[官方模型文档](https://ai.google.dev/gemini-api/docs/latest-model?hl=en) 明确支持 low/medium/high。摘要适配器对 3.5 Flash-Lite 保留 minimal，对 3.8 Flash 使用 low，并补回归检查；默认选择依据修正参数后的同批样本比较。
