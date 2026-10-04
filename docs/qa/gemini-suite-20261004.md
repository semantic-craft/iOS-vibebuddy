# Gemini 三用途接入验收 — 2026-10-04

阶段：实施中；本页只记录已经执行的检查，不能视为整套验收通过。

## 工作源与范围

集成分支 `codex/gemini-provider-suite`，基线 `5af77f161cd28386beeda8b6c98853811013f43e`。实现目标与门槛见 [PRD](../planning/backlog/gemini-provider-suite/PRD.md)，依赖见 [工单总览](../planning/backlog/gemini-provider-suite/TICKET-PLAN.md)。

用户已明确要求实施全规格并调用 implement-spec；本地分支/子工作树/提交合入按该流程进行。不推送、不发布、不替换共享已安装 App。原始工作区保留不动。

## 已执行：官方 SDK 对照

- 使用项目 `.envrc` 已有 Gemini 白名单，经 direnv 显式注入 Python 子进程；未回显 Key、未写 Keychain。编译及本地回归不加载凭据。
- Google 模型列表 HTTP 200；当前账户列出 `gemini-3.5-flash-lite`、`gemini-3.8-flash` 和两个 3.8 TTS 型号。模型列表没有列出 Live，但下述 Live 连接实测成功。
- 固定 Python `google-genai==2.25.0`，安装在独立工作树的临时虚拟环境，未增加产品依赖。请求尝试次数为 1。
- 文本：`gemini-3.5-flash-lite` Interactions，`store=false`、minimal thinking，简单协议探针约 1.50 秒，状态 completed。回包包含 model_output steps、output_text 以及 total_input/output/thought token 字段；不是摘要质量比较。
- TTS：`gemini-3.8-flash-lite-tts`，Kore，中文“请查询当前任务的状态。”；正文与 speech_metadata 分开，`store=false`。约 2.95 秒获得 175026 字节 WAV。生成音频成功，不代表人已实际听到。
- Live：`gemini-3.8-live`，AUDIO + output transcription、BLOCKING get_status。连续两轮文本触发，2 次工具调用/回包、2 次 turnComplete、357122 字节音频、6 次转写事件；只使用隔离的测试状态，没有执行真实任务操作。该探针证明模型协议，不证明麦克风、Swift 适配器或应用任务执行。

原始探针与无凭据结果暂位于集成工作树 `.scratch/gemini-acceptance/`，最终保存到持久证据目录再更新本页。

## 尚待执行

Swift 产品适配器验证、同批真实结果的摘要模型比较、两端构建、真实任务/隔离应用流程、设备实听、两轴代码评审与最终集成检查。真实长时限通话、安装和发布未执行。
