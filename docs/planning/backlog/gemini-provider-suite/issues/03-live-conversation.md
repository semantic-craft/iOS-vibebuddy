# GEM-03：在 Mac/iPhone 用 Gemini 通话并操作任务

Status: ready-for-agent
Blocked by: [GEM-01](01-configuration-summary.md)
日期：2026-10-04
Parent: [Gemini 三用途接入 PRD](../PRD.md)
参考：[官方研究](../../../../research/gemini-provider-official-research-2026-10-04.md) · [依赖总览](../TICKET-PLAN.md)

**What to build:** 用户在两端发起 Gemini Live 通话，连续查询任务，通过现有受控工具操作指定任务，并得到应用真实回执；打断、挂断、失败和重拨行为明确。

## 工作边界

- 增加 GeminiRealtimeSession 并接入两端现有通话与设置连接检查，使用 `gemini-3.8-live`。
- 把 setup、音频、转写、工具调用/取消、轮次结束与连接结束映射到现有事件；维持半双工和任务目标核验。
- 按 PRD 显式 BLOCKING，固定 SDK/schema 核对新协议，不复制过期示例。只复用现有动作，不扩展权限。

## Acceptance criteria

- [ ] 两端能保存实时模型/声音并建立通话；setup 确认后才显示连接就绪。设置检查不打开麦克风、不加载任务上下文或工具。
- [ ] 两端均完成真实音频往返和连续两轮问答，双方转写与轮次处理正确；一次 response 完成不关闭整通电话。
- [ ] 语音查询读取当前真实任务；在明确授权的可控任务上完成现有操作，应用层确认后才反馈成功，不声称 agent 已完成任务。
- [ ] 目标不明确/过期时沿用原核验拒绝；取消、打断后的旧调用和迟到回包不再执行，不重试有副作用动作。
- [ ] 打断、挂断关闭音频与会话；结束通话工具先满足原回执交付约定，晚到音频不重新播放。
- [ ] GoAway 预告与实际断开分开处理；确认供应商时限才显示正常到顶，网络/认证/配额故障仍为失败；重拨创建新通话。
- [ ] 保留现有通话暂停朗读机制，Gemini TTS 尚未交付时用已有朗读供应商验证；不实现透明会话恢复。
- [ ] 关键协议/协调器回归、两端构建和设备短通话通过；真实供应商长时限未测时单列，不用协议重放替代实测声明。

**验证先例：** VoiceCallCoordinatorTests、VoiceTargetCheckTests、ProviderLimitSignalTests。

**交付证据：** 两端连续对话、真实状态查询、受控操作回执、目标核验、取消/结束/重拨及必要的固定 SDK 对照。

## 执行与完成记录

遵循父规格的范围与验收规则；真实调用、设备听感、安装/发布与本地检查分别记录。缺少条件时完成可用检查并留下具体缺口，不能将模拟通过标为真实验收通过。只运行受影响的检查，保留其他会话改动。

2026-10-04 实现记录（设备验收未完成，保持开放）：

- 新增原生 `GeminiRealtimeSession`，用 `x-goog-api-key` 请求头建立连接，不把 Key 放入 URL。按固定官方 `google-genai 2.25.0` schema 发送 AUDIO、转写及显式 BLOCKING 工具声明；工具结果保留 id/name 并等待 socket 发送完成。
- Mac/iPhone 通话与设置连接检查均接入，默认 `gemini-3.8-live` / `Kore`。现有音频基础设施、任务目标核验与受控操作不变；连接检查仍不加载任务工具。
- 连接确认、连续轮次、输入/输出转写、取消身份、打断后迟到输出、关闭后旧连接回调隔离已实现。GoAway 只作预告；收到该预告后的正常 WebSocket 关闭才分类为供应商到顶。
- TDD 首次回归因适配器尚不存在而编译失败；实现后定向运行 GeminiRealtimeSessionTests、VoiceCallCoordinatorTests、VoiceTargetCheckTests、ProviderLimitSignalTests，45 项通过；真实调用测试默认跳过。`git diff --check` 通过。
- `GeminiLiveAcceptanceTests` 提供显式启用、90 秒有界的原生真实音频两轮检查，接受外部 PCM 与状态回执文件，不自动读取 Keychain。由集成验收记录实际调用结果。
- 待集成：两端构建、原生真实模型音频/状态调用、两端麦克风与扬声器实听、授权任务操作和真实时限。协议重放不等于设备验收。
