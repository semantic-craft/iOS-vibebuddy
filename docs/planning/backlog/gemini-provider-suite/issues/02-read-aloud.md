# GEM-02：在 Mac/iPhone 用 Gemini 朗读结果

Status: ready-for-agent
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
- [ ] 空/错误 MIME/过大音频、拒绝、限流与网络错误有界处理且可见；固定版本官方 SDK 对照产物与产品音频均记录格式。
- [ ] 受影响合成/队列测试与两端构建通过；分别记录生成音频、播放器完成、设备实听证据。

**验证先例：** SpeechSynthesisDecodingTests、MiniMaxSpeechTests、ChunkedSpeechSynthesizerTests、CompletionSpeechQueueTests。

**交付证据：** 两端试听及真实结果朗读、停止/取消、跟随/固定设置。声音生成成功不能替代设备实听。

## 执行与完成记录

遵循父规格的范围与验收规则；真实调用、设备听感、安装/发布与本地检查分别记录。缺少条件时完成可用检查并留下具体缺口，不能将模拟通过标为真实验收通过。只运行受影响的检查，保留其他会话改动。

尚未实施。完成时记录代码版本、实际检查、端到端证据及剩余限制。
