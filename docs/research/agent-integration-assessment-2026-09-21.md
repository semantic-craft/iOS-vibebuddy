# Agent 集成评估与 Grok ACP 接手结论（2026-09-21）

## 范围与证据

这份记录保留五家 agent 的研究方向，并把 Grok Build 的协议探针、代码实现和产品验收分开。它不宣布新的集成已经发布。1.3.24 的 Grok Build 仍是 hooks 观察与有限审批。

原评估针对 Claude Code 2.1.273、Codex CLI 0.153.4、cursor-agent 2026.09.18、Cursor 3.21.16 和 Grok Build 1.0.40。版本、竞品能力和本机安装状态都是当日快照。原稿中“领先”“公开项目中最完整”等比较没有完整的可复核样本，本记录不采用这些评级。

原始研究与实现已保存在分支 `claude/agent-integration-assessment-8b8054` 的提交 `25e3b53`；合入 `origin/main` 的验证基线是 `47cf62f`，其中 main 为 `366e3fe`。完整原稿可从保存提交读取。以下只把核对过的代码与资料作为落地依据。

## Grok Build 的控制边界

Grok 1.0.40 随程序分发的 `~/.grok/docs/user-guide/10-hooks.md` 说明，`PreToolUse` 的 allow 只是不阻止执行，不会替用户回答 Grok 自身的权限提示。因此当前 hook 审批不能保证批准默认模式下的终端会话。拒绝路径和 always-approve 模式另当别论。

`15-agent-mode.md` 描述了 `grok agent stdio`、`--no-leader`、会话创建、权限请求与取消。ACP 的标准会话创建需要先初始化，再提供 cwd 和 MCP servers；权限请求通过 `session/request_permission` 返回选择结果。参见 [ACP session setup](https://agentclientprotocol.com/protocol/v1/session-setup) 和 [ACP tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls)。这些资料支持“托管自己启动的进程”这一方向，不能证明能接管用户已运行的终端会话。

原会话留下的 Grok 1.0.40 探针记录还报告了：

- `cached_token` 认证可用；新会话 ID 与 hook 和磁盘会话目录一致。
- 问答扩展在线上使用 `_x.ai/ask_user_question`；应答以 `outcome` 为标签，accepted 带以问题文字为键的 answers。
- `_x.ai/queue/interject` 返回 Method not found，所以运行中的追加指令应排队到下一轮。
- 拒绝权限会以 cancelled 结束；只有本客户端发送过取消，才可标记为用户主动停止。
- 审批频率受用户自己的 permission mode 控制，不能假定启动参数会覆盖配置。

这些是原会话的实测记录，不是 ACP 对所有实现的保证。原会话的本地证据在 `.scratch/verify-vibebuddy/vb-grokacp-120328/`，工单在 `.scratch/agent-integration-2026-09/issues/01-grok-acp-host.md`。这些路径不随仓库发布。本次已核对历史命令记录；未把历史 HTTP 验收改称 Mac 或 iPhone 界面验收。

## 原型成熟度

原型包含 `GrokACPMonitor`、HTTP dispatch/answer/approval 接线、共享 ACP 传输和问答支持、Mac model 接线及 11 项 Grok ACP 测试。合入上述 main 后，`swift test --package-path VibeBuddyKit` 的 569 项和 `swift test --package-path VibeBuddyMac` 的 1159 项均通过。

接手时发现以下合并阻断：

1. `MenuBarModel.dispatch` 创建 `TaskDispatcher` 时没有传 grokACP。界面可以列出 Grok，但按 Start 会得到 unsupported。
2. `MenuBarModel` 的语音 answer/instruct 路径仍把 steer/startTurn 交给 Codex monitor。即使 HTTP 创建成功，语音也不能正确追加或继续 Grok 会话。
3. 隔离 Mac 配置强制禁用 Grok executable，尚无对应的受控 opt-in 验收入口。旧 daemon 测试不能证明 Mac 新任务与语音接线可用。

因此 PR #232 先只合并决策与研究文档。代码和面向用户的 README、CONTEXT、hook 设置文档变更留在独立代码分支；在修复入口并完成真实路径验收前，不把 ACP 能力写成 main 已支持。

下一次代码交付至少要验证：Mac New task、HTTP dispatch、allow/deny、问答、运行中排队、完成后继续、停止、语音路由，以及同会话 hooks 不产生第二张卡。还应检查停止与问答到达交错时不会遗留卡片。使用独立 bundle id、root、端口与 token，不覆盖已安装应用。

## 其余四家的后续研究方向

以下是原评估提出的候选事项，未在本次实现或全面重验，也不视作已确认缺陷：

| Agent | 候选事项 | 需要补的证据 |
| --- | --- | --- |
| Claude Code | Stop 中的后台任务信息；后台会话查询是否改用官方 CLI；已退出会话的 resume | 对照当前官方事件与命令契约，复现错误完成判定，核对现有 reducer 与后台会话实现 |
| Codex | rollout 可用性变化；queue 能否作为追加指令的备用路径 | 当前 daemon/rollout 覆盖与真实 Desktop 会话行为；不能仅由本机数据库存在推断文件协议被取代 |
| Cursor | 观测健康诊断、CLI status line、插件分发 | 诊断页面是否漏项及当前公开协议；保留 ADR-0016 和 ADR-0018 的控制边界 |
| Grok Bot | 已结案：只读会话集成于 2026-09-21 移除，只保留账户额度，见 [ADR-0031](../adr/0031-grok-bot-is-account-usage-only.md) | — |

Grok leader 的权限扇出、重启恢复、status line 和 active_sessions 注册表同样属于后续研究。`loadSession` 能力本身不等于已实现恢复；共享 leader 也不能自动获得操作其他客户端会话的授权。

## PR #233 落地验收（2026-09-21）

代码分支已合入当前 main，包括侧边栏、分隔条、上手清单、摘要与 iOS 发布准备。README 和 CONTEXT 保留 main 的现行措辞，仅补托管 Grok 的能力与限制。

- Mac New task 与语音 action 路由接入同一个 Grok host；隔离实例通过 `VIBEBUDDY_E2E_GROK_ACP=1` 和独立的 `root/grok` 显式启用，不回落到生产 executable。
- 取消任务会取消准备中的 ACP 请求和 question waiter。许可规则读取被阻塞时取消任务，旧代码会重新弹卡；新增回归在旧代码失败，修复后通过。
- 真实 Mac 验收发现 Grok hook 的 native promptId 会覆盖 ACP 的轮次映射，导致完成正文不可读。ACP start/stop 现在使用一致的 host turnID，旁路 hooks 不再改写完成映射。双轮回归在旧代码均取不到正文，修复后两轮正文与持久化记录均正确。
- 共享包 569 项、Mac 包 1162 项通过，Mac Debug 构建通过；独立代码评审未发现剩余阻断。
- 实际 Grok 1.0.40 + 隔离 Mac 实例已验证：Mac 新建任务、HTTP 派发、允许/拒绝、问题回答、运行中排队、停止及继续；同一会话的原生 hooks 也转发到 `/hook?agent=grok` 和 `/approval`，没有重复卡片。Mac 续问返回 `MAC_CONTINUED`，界面与 `/completion` 正文一致。
- 用 LLDB 在隔离 Debug App 中调用实际 `readVoiceStatus` 与 `performVoiceAction`，完成态语音指令走 Grok 并返回 `VOICE_ROUTED`；这验证 action handler，不冒充麦克风或云端语音识别验收。
- 许可测试在隔离 GROK_HOME 明确要求 `Bash(*)` 审批，允许后创建测试文件，拒绝后没有文件；未改变用户的 Grok 配置。隔离 App 用 SIGKILL 退出并核验端口释放。

这些验收不等于 iPhone/Watch 已验收，也不包含麦克风识别、leader 接管或跨 App 重启恢复。手机与 Watch 的发布验收随 iOS 1.3.24 (53) 单独记录。原型阶段其余四家的候选事项继续保留为研究，不随本次发布宣称完成。
