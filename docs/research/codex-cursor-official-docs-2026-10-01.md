# Codex / Cursor 官方接入评估（2026-10-01）

核对日期：2026-10-01。代码基线：`451ecfcab8b8e3667165b1c1ddca22b0b516218c`。
本次只研究并生成本地协议，未修改应用、运行配置或凭据，未启动共享服务、升级 CLI、提交或推送。

## 结论

最值得投入的是协议兼容、审批失败语义和事件处理效率。现有 Codex app-server、Cursor ACP 与 Cloud Agents v1 接入不需要重写。新能力按使用场景增加；没有基准测试，不能承诺速度或内存改善百分比。

| 顺序 | 工作 | 用户可感知的效果 | 判断依据 |
| --- | --- | --- | --- |
| P1 | Codex 新版 rollout 回放认证、协议审计可独立运行 | 减少“版本未知”和误导性的接入状态 | 本机 CLI 0.159.2；项目 rollout 门控只接受 0.151.x / 0.153.3 |
| P1 | 隔离验证 Cursor 审批 Hook 的空响应和失败路径 | 避免本地服务不可达时，工具意外被阻止 | 当前官方 Hook 语义与脚本注释存在待验证差异 |
| P1 | Codex 通知减量、缓冲上限和恢复策略 | 降低繁忙会话的事件积压，改善恢复后的状态准确性 | 当前通知 AsyncStream 无界；未配置 opt-out |
| P2 | Codex 按需历史分页、目标进度与后台终端展示 | 长任务更容易查看，避免加载整段历史 | 当前官方协议和本机生成 schema 已提供相应能力，部分实验性 |
| P2 | Cursor ACP 本地 MCP 加载验收 | 托管任务能可靠使用项目已有工具 | 官方支持项目/用户 MCP；代码传入空 mcpServers，不能由此推断禁用或生效 |
| P2/P3 | Cursor 活跃云任务 SSE + 轮询兜底 | 减少完成通知等待下一轮轮询的延迟 | 当前每 20 秒轮询；官方提供事件续连 |

## 有日期的上游更新

### Codex

[官方 changelog](https://learn.chatgpt.com/docs/changelog)截至本次查询的最新 CLI 条目是 **2026-09-30 的 0.159.3**，新增账户安全设置提醒，不是本项目接入性能修复。本机已安装 **0.159.2**。

与项目更有关的是 **2026-09-29 的 0.159.0**：历史 item 定位分页、可选 `instant_interrupt`，以及 macOS 沙箱 TLS、代理环境、Unix socket 长软链接路径和 steering WebSocket 连续性修复。不能把这些发布说明直接当成本应用已经支持相应行为的证据。

`instant_interrupt` 可以列入后续“运行中补充指令”的验收项；项目已有 `turn/steer`，无需再造控制入口。是否支持、线程归属及中断行为要随实际客户端和配置验证。

### Cursor

[总 changelog](https://cursor.com/changelog)最新可见条目为 **2026-09-23 Rollouts / Security Review**，侧重 Teams/Enterprise 部署监测与 PR 审查，未发现它改变本项目使用的本地接入契约。9 月还发布了 Projects（9/10）和自托管机器（9/2）；可以改善长任务运行方式，但 Projects 关系能否通过 API 读取仍需证据。

[CLI changelog](https://cursor.com/docs/cli/changelog)最新可见日期是 **2026-08-26**，包含 `agent persist` 及 detach/attach/list/stop。若常用终端长任务，值得验证 VibeBuddy 能否持续发现断开后的任务；CLI attach 不等于 ACP 接管。没有找到 9/21 后新的带日期 CLI 条目，不代表期间没有未记载变化。

[2026-04-29 SDK/API 公告](https://cursor.com/changelog/sdk-release)已介绍 agent + per-prompt run 及 SSE。它不是本周才出现的功能；项目 ADR-0018 已选择 v1 轮询。

ACP、Hooks、Cloud API 当前文档未显示可靠的页面更新时间，因此下文称“当前文档能力”，不把它们全部称作最近新增。

## Codex：实现与官方协议的差距

### 本地只读核对

- `codex --version`：`codex-cli 0.159.2`。
- `probe.py audit` 未完成：默认共享 socket 不存在，脚本在 daemon version 阶段退出。没有为了审计而启动 daemon；这不代表 Desktop 自身不可用。
- 分别生成普通及 `--experimental` JSON schema 成功。Monitor 中以字面量调用的请求方法均存在；这只检查名称，不证明全部字段和运行行为兼容。
- `TurnSteerParams`、`PermissionsRequestApprovalParams` 必填字段与现有审计预期一致。
- 实验 schema 包含 `thread/backgroundTerminals/list|terminate|clean`；普通 schema 包含目标及历史接口。
- 本机实验 schema 的 `ThreadItemsListParams.cursor` 是联合类型，支持 opaque cursor 或 item anchor（anchor 还要求 turnId）；不能只检查顶层字段名就认定此功能缺失。历史实现使用 opaque cursor。

可复核位置：

- `VibeBuddyMac/Sources/VibeBuddyMacCore/ObservationHealthDetector.swift:879`：rollout 认证门控。
- `VibeBuddyMac/Sources/VibeBuddyMacCore/CodexAppServerClient.swift:98`：无界消息流。
- `VibeBuddyMac/Sources/VibeBuddyMacCore/CodexAppServerMonitor.swift:200`：初始化能力；`:268`：历史发现及订阅。
- `VibeBuddyMac/Sources/VibeBuddyMacCore/CodexAppServerReducer.swift:70` 起：消费生命周期、完整 item、usage，未消费文本 delta。
- `tools/codex-integration/probe.py:247`：审计依赖活跃 daemon。

建议让静态 schema 审计与服务连接审计分别报告。rollout 门控要通过新版真实事件回放后更新，不应简单放开所有版本。CLI 版本也不能代替 Desktop 实际事件生产者版本。

### 性能与恢复

[App-server 文档](https://learn.chatgpt.com/docs/app-server)提供精确名称的通知 opt-out、分页和状态数据库列表读取。建议先抑制本项目不消费的文本 delta，再限制应用缓冲；保留审批、生命周期、完整结果和 usage，溢出时明确重同步，不能静默丢关键事件。

服务过载错误 `-32001` 可按官方建议退避并加入抖动；读请求可以恢复，创建任务、发送消息等写请求不能不加区分地重试。历史按需读取，活跃线程发现不受旧历史分页窗口限制。

验收应比较同一事件回放的峰值缓冲、内存及状态延迟，并确认断线、重连和过载时不重复审批、不丢完成通知。

### 增量能力与边界

目标进度、MCP 状态和后台终端列表适合补进任务详情；终止进程仍是独立用户动作。当前 app-server/WebSocket 在官方文档中仍标为实验性，应保留版本检查及被动观测路径。

`docs/codex-integration.md` 的真实验收已证明：共享服务连接正常不等于能够订阅 Desktop 所有线程。不能恢复另一个 writer 的活跃线程来强行接管；新版仍需验证这个边界。

[Hooks 文档](https://learn.chatgpt.com/docs/hooks)支持异步通知并要求配置变更后重新信任。项目 `HookInstallerAgents.swift:86` 已将可异步的状态通知设为异步、短超时，审批保留同步；此项已实现，无需作为新增优化重复做。当前未证明所有 Desktop 原生审批都能经 Hook 到达 VibeBuddy。

## Cursor：优先验证错误语义，再补实时云事件

### 审批 Hook

[当前 Hooks 文档的 Exit code behavior](https://cursor.com/docs/hooks)说明：权限 Hook 退出码为 0 时解析 JSON，无效或不匹配 schema 的输出会阻止动作；其他失败的默认处理与之不同。

`hooks/approval-hook.sh:39` 仍注释“401 → 空响应 → 继续正常流程”，最终 `exit 0`。空输出是否被当前 CLI/IDE 特判为无意见，不能仅凭网页定论。这是**待复现风险，不是已确认故障**。

下一次实施应隔离覆盖服务不可达、401、超时、空内容、有效 allow/deny，观察实际工具执行结果，再决定响应格式和失败策略；同时保留当前原生审批意图。

### ACP 和 MCP

[ACP 官方文档](https://prod.cursor.com/docs/cli/acp)包含 session load、权限、问答和计划等协议。项目已经支持托管会话恢复、取消、审批、问答和计划；不要把现有功能再次列为待接入。

官方确认项目/用户 `.cursor/mcp.json` 可用，团队 dashboard MCP 不支持 ACP。建议用隔离项目验证自动加载；`mcpServers: []` 本身不足以判断配置被禁用。也没有官方证据保证可接管任意 IDE 会话。

### Cloud Agents

[Cloud Agents API](https://prod.cursor.com/docs/cloud-agent/api/endpoints)提供按 run 的 SSE、`Last-Event-ID` 续连；过期返回 `410 stream_expired` 时应读取终态。项目 `CursorCloudAgentMonitor.swift:45` 当前默认 20 秒轮询。

有云任务延迟需求时，为活跃 run 增加 SSE，并保留列表发现和异常兜底；测量终态到通知的延迟、重连重复事件和过期恢复。此前未配置云 API 的本机场景不会因此改善本地会话观测。

同页仍将 v1 webhooks 标为 coming soon，不能为了已有 Cloudflare 入口就接旧 v0 webhook。Cloudflare 可继续用于已有远程访问用途，和本轮协议优化分开判断。

## 实施边界与完成条件

建议首轮只做三个 P1：新版事件认证、Cursor Hook 失败路径验收、Codex 事件减量及恢复。用隔离 daemon/项目和真实代理事件验收；生产安装和重启另按已有项目授权边界处理。

本次没有跑应用构建或端到端任务，因为没有修改运行代码。当前证据是官方原文、源码对照及本机生成协议；性能收益、Desktop 全量审批覆盖、Cursor 空响应语义均未获得实机验收。
