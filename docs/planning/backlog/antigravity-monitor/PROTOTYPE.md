# Antigravity 接入原型结论（2026-10-04）

**结论：关键读取路径可用，现成看板的机制可以借鉴，但不能原样照搬。**
CLI 配额、日志正文、headless hooks，以及桌面的会话列表和步骤查询均已获得真实数据。
问题等待已在 CLI / 桌面画面中对照；尚未证明权限审批等待、所有结束原因或三端产品链路。
这次交付是接入可行性原型，不是首版产品验收通过。

## 环境与产物

- 验证版本：`agy 1.2.16`；Antigravity 桌面 app `2.19.1`，bundle `com.google.antigravity`。
  当前 app 的 UI 有 Install IDE；本次没有独立 Antigravity IDE 实例的验收证据。
- 起始仓库 HEAD：`63145f24140d74cffeb6155f70c0ebd26e0a2992`，分支 main。
  已有未提交研究、范围文档与 backlog 索引改动得到保留。
- 原型源码保存在 `codex/prototype-antigravity-20261004`，提交 `55ad3f97`，目录 `VibeBuddyMac/Prototypes/AntigravityMonitor/`。生产分支不包含一次性原型代码。
- 持久证据目录：`~/Projects/_shared-work/iOS-vibebuddy/antigravity-prototype-20261004/`。
  `source-snapshot/` 保留原型源文件，`manifest.json` 记录 SHA-256；原始合成任务材料不进 Git。

## 真实观察

| 能力 | 结果 | 证据文件（相对证据目录） |
| --- | --- | --- |
| 账户配额 | `/usage` JSON 成功，Gemini 与 Claude/GPT 两组，各含 weekly / 5h、fraction、reset time；该调用报告 0 turns / 0 tokens | `read-only/report.json` |
| 桌面已有会话发现 | `GetAllCascadeTrajectories` 可列出现有会话、工作区、步骤数和 RUNNING / IDLE；运行中会话与原应用画面对照 | `read-only/report.json`，仅保存脱敏概要 |
| CLI headless 生命周期 | 真实读文件任务：开始、工具后置、模型调用后置、Stop hooks 均执行；`fullyIdle=true`，`terminationReason=NO_TOOL_CALL`，结果 SUCCESS | `cli-read/report.json`、`hooks.jsonl`、`stream.jsonl` |
| CLI 问题等待 | 真实交互式终端展示 Alpha / Beta；短日志最后一行是 DONE 的 PLANNER_RESPONSE，包含尚未取得结果的 ask_question | `cli-wait.json`；终端操作回读留在本次会话 |
| CLI 回答与结果 | 在原终端选 Alpha，运行恢复，返回 `ANTIGRAVITY_WAIT_DONE`；日志追加回答工具结果和最终正文 | `antigravity-cli-final-transcript.json` |
| 桌面问题等待 | 原生 UI 展示问题及选项；列表仍报 RUNNING，步骤接口才报 ASK_QUESTION / WAITING，并包含 requestedInteraction | `desktop-timeline.json`、`desktop-wait-steps.json` |
| 桌面取消 | 测试会话随后在应用中被取消；UI 明示 User cancelled agent execution，步骤为 CANCELED；未自动重启该任务 | `desktop-cancelled-steps.json` |
| 长结果完整性 | 80 行输出 5,600 字符（含末尾换行）；短日志 content 4,120 字符、有截断标记；full 日志 5,599 字符，忽略末尾换行后完全一致 | `cli-long/report.json`、`integrity.json`、两个 transcript 文件 |
| 状态与额度归一化 | 从上述真实捕获生成独立池、问题等待、成功结束、取消等快照，取消不生成成功提醒 | `normalized.json` |

CLI 短任务约 13.25 秒完成（冷启动 init 约 6.51 秒）；长结果任务约 28.20 秒。
这些是任务耗时，不是 monitor 的响应延迟 SLA。桌面采样间隔约一秒，未量得 UI→RPC 的严格端到端延迟。

## 必须修订的接入设计

1. **正文优先 full 日志。** Caw 的短日志可用于发现/部分状态，但本机实测会截断长正文。
   优先 `transcript_full.jsonl`，short fallback 必须标明摘录。缺失全文不能静默当完整结果。
2. **桌面读取列表 + 当前步骤。** Deck 的总状态只做粗粒度发现；WAITING 步骤优先于列表 RUNNING。
   `requestedInteraction` 是问题内容来源。此次仅验证 ask_question，不能推定所有审批结构相同。
3. **DONE 是步骤状态，不是会话完成。** 正在等待回答时，CLI 最新已落盘 planner 行也是 DONE。
   必须区分工具请求与结果，不能把“最后一行 DONE”或“30 秒没更新”当结束。
4. **结束与取消需要额外证据。** 桌面取消后短日志仍停留在提问前的 planner 行；仅 tail 日志会遗留假等待。
   使用步骤 CANCELED / 明确结束事件校正，原型归一化将其表示为终止且 outcome=cancelled，不宣称成功。
5. **新版 hooks 要重接契约。** headless 项目级 `.agents/hooks.json` 实测可用，payload 使用 conversationId、
   workspacePaths 等 camelCase，事件名由 wrapper 标记。当前生产 parser 的旧字段不能直接承接。
   同目录交互式 CLI 运行未写入这份 hook 捕获文件，原因未定位；不能把 headless 成功扩大为交互式 hooks 已通过。
6. **配额首选官方只读命令。** 已得到真实组和窗口；无需为本切片引入 OAuth 提取、TUI 抓取或第三方账号管理。
   两端是否同一登录账户尚未验证，不允许在产品中默认认定相同。

## 原型验证边界与剩余工作

- 已完成：真实来源探针、短/长结果完整性比较、CLI 问题等待/恢复、桌面问题等待/取消、信号回放、单文件状态演示。
- 未完成：真实权限审批等待、终止失败/后台任务的全路径、交互式 hooks 差异定位、重启恢复、多会话切换的完整验收。
- 未完成：独立 IDE 版本、Mac/iPhone/Watch 产品接线、APNs/通知、手机长结果实际渲染及账户归属核验。
- HTML 的故障/失联/后台任务按钮是设计推演；Python 与 JavaScript 语法检查通过，未编写原型测试套件。
  浏览器策略拒绝 `file://`，没有绕过该限制，尚未进行页面点击/视觉验收。
- 未修改生产源码、生产 hook 配置、登录 token 或已安装 VibeBuddy；未启动第二个生产实例或绑定 :9876。
  原型只在独立工作区设置被动 hooks；交互式 CLI 对该测试工作区做了信任确认，并在结束后用 /exit 退出。
  headless 子进程均已退出。桌面测试保留为取消的原生会话；没有删除用户记录。
- 原型代码已提交到上述独立本地分支；未推送。实现以此提交和持久证据为输入。

## 下一阶段

可以据此进入 `/to-spec`：把配额 adapter、full transcript reader、桌面 list+steps monitor 分成端到端切片。
将交互式 hooks、审批等待、终止/恢复和独立 IDE 覆盖列为实现前置验证项，不能用现有原型结论跳过。
首版范围仍按 [PRD](PRD.md)，不因本次原型覆盖不足而自动缩小。
