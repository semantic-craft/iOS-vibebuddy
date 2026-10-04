# GEM-02：在 Mac/iPhone 用 Gemini 朗读结果

Status: ready-for-human
Blocked by: [GEM-01](01-configuration-summary.md)
日期：2026-10-04
Parent: [Gemini 三用途接入 PRD](../PRD.md)
参考：[官方研究](../../../../research/gemini-provider-official-research-2026-10-04.md) · [依赖总览](../TICKET-PLAN.md)

**What to build:** 用户选择 Gemini 朗读供应商、声音与风格，能够试听、手动听取真实任务结果，并按现有开关接收自动播报；可以跟随摘要供应商或单独固定。

## 工作边界

- 增加 Gemini SpeechSynthesizer，打通两端设置、预置声音/风格与已有分段合成/播放器。
- 使用 3.8 Flash-Lite TTS 与完整 WAV；待朗读正文和 speech_metadata 风格分离，显式关闭 interaction 存储。
- 沿用已有队列与阅读语义；不引入新流式播放器、声音克隆或声音设计。

## Acceptance criteria

- [ ] 两端能选择 Gemini TTS、保存模型/声音/风格并试听；默认使用 `gemini-3.8-flash-lite-tts`，模型可编辑。
- [ ] 跟随 Gemini 摘要时可自动解析到 Gemini TTS；固定其他供应商时不受摘要切换影响，无 Key/供应商不可用时不暗中切换。
- [ ] Mac/iPhone 均朗读真实结果，中文、英文标识符和数字可听清，正文事实不被增删；需要比较音色质量时按 PRD 对比 Flash TTS 并记录依据。
- [ ] 暂停、停止、跳过、重播和连续队列遵循现有行为；已取消的合成结果不进入播放队列，听取不改变已读状态。
- [ ] 已有通话可暂停朗读，手动队列恢复沿用现有规则；Gemini 与 Gemini 的完整联动留到 GEM-04。
- [x] 空/错误 MIME/过大音频、拒绝、限流与网络错误有界处理且可见；固定版本官方 SDK 对照产物与产品音频均记录格式。
- [ ] 受影响合成/队列测试与两端构建通过；分别记录生成音频、播放器完成、设备实听证据。

**验证先例：** SpeechSynthesisDecodingTests、MiniMaxSpeechTests、ChunkedSpeechSynthesizerTests、CompletionSpeechQueueTests。

**交付证据：** 两端试听及真实结果朗读、停止/取消、跟随/固定设置。声音生成成功不能替代设备实听。

## 执行与完成记录

遵循父规格的范围与验收规则；真实调用、设备听感、安装/发布与本地检查分别记录。缺少条件时完成可用检查并留下具体缺口，不能将模拟通过标为真实验收通过。只运行受影响的检查，保留其他会话改动。

本地实现（2026-10-04，集成基线 `d3a2231f`）：增加共享 Gemini Interactions TTS 适配器，正文与风格注解分离、`store=false`，解析原始 `steps[].content[]` 音频而非 SDK 的便利属性。下载和解码音频均有上限，验证完整 PCM16/24 kHz/单声道 WAV；支持取消、错误分类以及已有分段/队列路径。启用两端共用的朗读供应商/预置声音/风格设置，Mac 隔离运行显式读取已注入的 Gemini Key；手机沿用 provider.apiKey 路径。

- 官方协议依据：[TTS 指南](https://ai.google.dev/gemini-api/docs/speech-generation)，Google GenAI SDK 2.25.0；原始 REST 音频位于 `steps[type=model_output].content[type=audio]`，`output_audio` 是 SDK 便利属性。
- 定向 Kit 检查：`GeminiSpeechTests|VoicePurposeSettingsTests|VoiceCatalogTests|VoiceDefaultsInCatalogTests|VoiceStyleTests|ChunkedSpeechSynthesizerTests|CompletionSpeechQueueTests`，46 项通过；真实调用测试默认关闭。红阶段先复现缺失合成器及供应商无法跟随，随后转绿。
- 真实合成入口：仅显式设置 `GEMINI_SPEECH_ACCEPTANCE=1` 才运行 `GeminiSpeechTests/liveGeminiSpeech`，使用已有环境 `GEMINI_API_KEY`，可由 `GEMINI_SPEECH_OUTPUT` 保存 WAV；测试不读取 Keychain、不打印 Key 或正文。
- 仍待集成验收：真实 Swift 合成、两端构建、设备试听/任务结果实听与队列控制。音频生成与播放器完成分别记录，不能替代听感验收。此工单保持未完成，由 GEM-04 汇总证据。

## 集成进度（2026-10-04）

代码已合入 `codex/gemini-provider-suite`；具体模型调用、构建、回归、评审和未测边界统一见[验收记录](../../../../qa/gemini-suite-20261004.md)。上文切片记录反映当时状态，以本段与验收记录为最新进度。

Swift TTS 已实际生成中文样例；Mac/iOS 构建通过。真实长文检查发现 WAV 分段拼接截断，已纳入同一轮修复与回归。待 Mac/iPhone 实听、正文完整性与队列控制验收；音频文件生成不是播放/听感通过。
