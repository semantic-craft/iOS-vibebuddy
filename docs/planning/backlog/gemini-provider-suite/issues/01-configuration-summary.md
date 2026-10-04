# GEM-01：配置 Gemini 并获得真实任务摘要

Status: ready-for-human
Blocked by: None（可以立即开始）
日期：2026-10-04
Parent: [Gemini 三用途接入 PRD](../PRD.md)
参考：[官方研究](../../../../research/gemini-provider-official-research-2026-10-04.md) · [依赖总览](../TICKET-PLAN.md)

**What to build:** 用户在账户及摘要设置中配置 Gemini，完成一轮真实 Claude/Codex 任务后，Mac 与配对 iPhone 能显示来源准确的 Gemini 摘要；重启后配置和新 Key 仍保留。比较两种候选模型并记录默认选择。

## 工作边界

- 建立供应商身份、设备本地凭据和摘要用途设置；删除两端持续清理 Gemini 的退役逻辑，保留其他供应商的设置。
- 摘要通过原生 Swift Interactions 独立请求完成，显式关闭 interaction 存储，不携带工具；复用现有内容呈现和通知决策。
- 当前切片只开放已实现的摘要能力。朗读和通话选项由后续切片各自启用，不向用户提供连接后必然失败的占位功能；跟随摘要但 TTS 尚不可用时沿用现有不可朗读状态。
- 修订 ADR-0001 说明重新引入的总目标及当前已交付能力，保留历史记录。

## Acceptance criteria

- [ ] 两端相应设置能保存/读取 Gemini 凭据与摘要用途配置；按既有职责由来源 Mac 生成摘要，手机不新增另一套摘要服务或同步 Key。
- [ ] 用隔离设置/凭据回放旧退役迁移场景，证明新配置不被删；已有显式选择保留，功能不会自动启用，缺 Key 或旧型号不可用时反馈清楚。
- [ ] 真实完成轮次在 Mac 和配对手机上显示正确摘要，遵循语言/内容风格、180 字通知与 900 字朗读呈现契约；只展示最终正文。
- [ ] 通知 12 秒决策时限、取消、生成期间新轮次及配置变化继续生效；失效结果不发布，无静默供应商/模型回退。
- [x] 同批经授权的真实样本比较 `gemini-3.5-flash-lite` 与 `gemini-3.8-flash`，记录耗时、用量、超时和事实准确性，按 PRD 规则落实默认值，仍允许用户修改。
- [x] 固定官方 SDK 版本做必要的协议对照；普通用户沿用 Keychain，开发凭据显式注入，错误和日志不回显 Key/带 Key URL/完整正文。
- [ ] 受影响配置、摘要/内容呈现回归检查及 Mac/iOS 构建通过；真实摘要验收证据明确来源、轮次、模型与结果。

**验证先例：** VoicePurposeSettingsTests、CompletionSummaryTests、CompletionSummaryPreferencesTests、ContentPresentationTests。优先从摘要服务及设置行为验证，不逐个测试内部构造函数。

**交付证据：** 默认模型比较结论、隔离真实摘要流程、配置迁移与构建结果。仅有 SDK 调通或模拟响应不算摘要切片完成。

## 执行与完成记录

遵循父规格的范围与验收规则；真实调用、设备听感、安装/发布与本地检查分别记录。缺少条件时完成可用检查并留下具体缺口，不能将模拟通过标为真实验收通过。只运行受影响的检查，保留其他会话改动。

2026-10-04：配置和摘要代码切片已实施，完整验收仍未关闭。

- 恢复 Gemini 摘要供应商及 Mac 账户设置；两端启动不再删除 Gemini Key/偏好。当前语音用途尚未启用；手机摘要仍由来源 Mac 提供，手机 Key 入口随后续语音切片开放。
- 原生 Interactions 请求显式 `store=false`，没有 tools/history；只解码最终 `model_output`，排除思考、工具输出与未完成结果，映射用量及安全错误。保留现有取消、轮次/配置失效和呈现限制。
- 暂定默认 `gemini-3.5-flash-lite`，由集成验收同批比较后定案。显式旧型号保留；404 提示选择受支持文本模型，设置可恢复默认。Gemini E2E 凭据只读 `GEMINI_API_KEY`，缺失不回退个人 Keychain；普通用户仍用 Keychain。
- 协议核对固定 Google JS GenAI [v2.24.0 Interactions schema](https://github.com/googleapis/js-genai/blob/v2.24.0/src/gaos/models/interactions/interaction.ts)、[model-output](https://github.com/googleapis/js-genai/blob/v2.24.0/src/gaos/models/interactions/model-output-step.ts)及 usage/generation-config。
- 设置回归先复现 Gemini 选择被读成 nil，再通过；HTTP 服务回放覆盖最终正文/用量、无状态认证请求、拒绝残缺及工具输出、不可用型号与错误 Key。受影响 Mac 26 项、Kit 9 项通过，真实模型调用未在此切片执行。
- 检查基线 `a1c94ef5` 加本切片未提交差异；完整源指纹和日志：`~/Projects/_shared-work/iOS-vibebuddy/gemini-suite-20261004/gem01-local-checks/` 下 mac/kit 的 results.json。
- 剩余：集成分支真实摘要比较、Mac/配对手机来源与轮次验收、两端原生构建；由 GEM-04 汇总。尚无安装、发布或用户验收结论。

## 集成进度（2026-10-04）

代码已合入 `codex/gemini-provider-suite`；具体模型调用、构建、回归、评审和未测边界统一见[验收记录](../../../../qa/gemini-suite-20261004.md)。上文切片记录反映当时状态，以本段与验收记录为最新进度。

默认已由同批真实样本比较定为 `gemini-3.5-flash-lite`；3.8 Flash 参数兼容修复后仍可手动选择。摘要、朗读与通话均已开放，Mac 原生设置及生产呈现接口已调用成功，两端构建通过。待配对物理手机接收新任务摘要、两端凭据/配置重启及设备通知验收；不因代码完成删除工单。
