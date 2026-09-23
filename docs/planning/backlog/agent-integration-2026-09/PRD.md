# PRD — 五家 agent 集成补齐（2026-09 评估后的工单集）

Status: ready-for-agent (2026-09-21)
Owner: vibebuddy
Source: `docs/research/agent-integration-assessment-2026-09-21.md`（worktree 分支 `claude/agent-integration-assessment-8b8054`）：对照 Claude Code 2.1.27x、Codex 0.153.4、Cursor CLI 2026.09.18、Grok Build 1.0.40 官方文档与 happy / claudecodeui / vibe-kanban / grok-app 等开源项目的评估；Grok ACP 报文形状来自本机只读探针（scratchpad `acp_probe*.py`，2026-09-21）。
Related: ADR-0011（Codex app-server）、ADR-0016（Cursor 观测与控制，ACP 托管在其修正案 1/2）、ADR-0018（Cursor Cloud）、`docs/multi-cli-hook-setup.md`、`docs/codex-integration.md`、`.scratch/mac-app-store/`（分发形态与沙盒边界）

## Problem Statement

评估结论：Claude Code、Codex、Cursor 三条线已达到或超过公开项目的最高水平；Grok Build 明显落后（hooks 只读、审批仅在 `always-approve` 下有效、无答问 / 追加指令 / 停止 / 派活）；Grok Bot 是对官方客户端私有网关的只读镜像，官方自带手机端，不再投入。三家大厂都已自带第一方手机遥控（Claude Remote Control、Codex Remote、Cursor iOS + `/remote-control`），唯独 Grok Build 没有——这是我们最大的空白，也是唯一没有第一方竞争的 agent。

评估同时发现三处内部缺口：Claude 的 `Stop.background_tasks` / `session_crons` 未读（还有后台工作的会话被标成完成）；Claude 后台会话状态读的是官方声明不稳定的 `~/.claude/jobs/*/state.json`（官方支持 `claude agents --json`）；观测健康诊断没有 Cursor 行。

## Solution

按价值顺序拆成独立工单，每张都能单独交付与验收：

1. **Grok Build ACP 托管**（01）：像 `CursorACPMonitor` 托管 `cursor-agent acp` 一样，用 `grok agent --no-leader stdio` 托管 vibebuddy 派发的 Grok 会话，一条管道拿到审批（`session/request_permission`）、答问（`_x.ai/ask_user_question`）、续接（`session/prompt`）、停止（`session/cancel`）、派活（`session/new`），`ControlChannel.acp` 上桩。hooks 继续给用户自己开的 TUI 会话当状态灯。
2. **Grok 两项实测与恢复**（02）：leader 模式是否把权限请求扇出到第二个 client（决定能否旁路挂上用户自己的 TUI 会话）；托管会话在 daemon 重启后的恢复（`session/load`）与终端续接（`grok -r <id>`）。
3. **Grok status line + 活跃会话名册**（03）：`[ui.status_line] type="command"` 转发（与 Claude 同构）补上下文 / 成本 / worktree；`~/.grok/active_sessions.json` 做存活兜底。
4. **Claude 完成判定读后台任务**（04）：`Stop` 的 `background_tasks` / `session_crons` 非空时不进 done。
5. **Claude 后台会话改读 `claude agents --json`**（05）。
6. **Cursor 观测健康诊断补行**（06）。
7. **Codex 退化预案**（07，观察项）：rollout → SQLite 迁移的检测与降级说明；`codex queue` 作 steer 兜底。
8. **分发形态**（08，决策项）：Claude 插件 / Cursor 插件 / Swift 安装器，随 1.3 陌生路径一并定。

## Grok ACP 探针事实（2026-09-21，grok 1.0.40，本机）

- `grok agent --no-leader stdio`：`initialize` 返回 `agentCapabilities.loadSession=true`、`sessionCapabilities.{list,resume,close}`、`authMethods=[cached_token, grok.com]`、`_meta.modelState.availableModels`（含 `totalContextTokens`、`reasoningEfforts`）。`authenticate {methodId:"cached_token"}` 成功。
- `session/new {cwd, mcpServers:[]}` 返回 `sessionId`，**与 `~/.grok/sessions/<cwd>/<id>/` 目录名和 hook 的 `sessionId` 相同**——hooks、会话目录富化与 ACP 描述同一个会话；托管进程里安装的 hooks 照常触发（`hook_execution` 更新里能看到 `global/vibebuddy:*`）。
- 扩展方法在线上带下划线前缀：`_x.ai/ask_user_question`（agent → client 请求）`{sessionId, toolCallId, questions:[{question, options:[{label, description}], multiSelect}], mode}`；不带前缀的名字返回 "unknown ACP extension method"。`_x.ai/queue/interject` 不是 ACP 扩展（Method not found）→ 追加指令只能排队为下一条 prompt。
- `session/request_permission`（标准 ACP）：`{sessionId, toolCall{toolCallId, kind: execute, title, rawInput{variant: Bash, command, description}, _meta["x.ai/tool"]{name: run_terminal_command, kind, label}}, options:[{optionId: always-allow, kind: allow_always}, {allow-once, allow_once}, {reject-once, reject_once}, {reject-always, reject_always}]}`；回 `{"outcome":{"outcome":"selected","optionId":…}}`。拒绝后 `tool_call_update.status=failed`，**该 turn 以 `stopReason: cancelled` 结束**（Grok 把拒绝算 `StopCancelled/permission_rejected`）。
- `session/update` 的 `sessionUpdate`：`agent_message_chunk`、`agent_thought_chunk`、`tool_call`（`title` 是 Grok 工具名如 `write`/`ask_user_question`，`rawInput` 是工具入参，`_meta["x.ai/tool"].kind`）、`tool_call_update`（`status: failed/completed`，`kind`，`locations`）、`tool_call_delta_chunk`、`session_info_update {title}`、`available_commands_update`。
- `_x.ai/session_notification` 的 `update.sessionUpdate`：`pending_interaction {tool_call_id, kind: permission|question}`、`interaction_resolved`、`turn_completed {prompt_id, stop_reason, usage{inputTokens, outputTokens, totalTokens, costUsdTicks…}}`、`response_completed`、`hook_execution`、`last_turn_summary`。
- `session/prompt` 响应 `{stopReason: end_turn|cancelled, _meta{promptId, totalTokens, modelId, …}}`；`session/cancel` 通知 → `stopReason: cancelled`。
- `_x.ai/ask_user_question` 应答：`{"outcome":"accepted","answers":{<question>:<label>},"partial_answers":false}`（`outcome` 为内部标记，变体 accepted / chat_about_this / skip_interview / cancelled；已实测被接受）。
- 权限模式随用户 `~/.grok/config.toml` 的 `[ui] permission_mode`；`grok --permission-mode default agent stdio` 与 `session/new _meta.yoloMode=false` 都**不能**覆盖它（本机 `always-approve` 下三种写法都自动放行）。项目 `.grok/config.toml` 的 `[ui] permission_mode = "ask"` + `[permission] ask` 规则加 `--trust` 可以（探针 5 拿到并回答了两次 `session/request_permission`）。结论：托管会话的审批频率是用户自己的 Grok 设置，vibebuddy 不改它。

## User Stories

1. As a 手机用户, I want 从"New task"给 Grok Build 派一个任务并在它要权限、要答案时在手机上处理, so that Grok 也能像 Codex / Cursor 一样离开电脑跑。
2. As a 手表用户, I want Grok 托管任务的审批卡与问题卡出现在手腕上, so that 三个 agent 的体验一致。
3. As a 手机用户, I want 对托管的 Grok 任务发追加指令、结束后续接、运行中停止, so that 不必回终端。
4. As a Mac 用户, I want 用户自己在终端开的 Grok 会话继续以 hooks 观测、状态和提醒不变, so that 托管不改变已有行为。
5. As a Mac 用户, I want Claude 会话在还有后台任务或定时循环时不被标成"完成", so that 不会在它还在干活时收到完成提醒。
6. As a Mac 用户, I want Cursor 的观测健康出现在设置页诊断里, so that 三个 agent 的健康视图完整。

## Out of scope

- Grok Bot 任何新能力（冻结只读）。
- Claude Channels（research preview，需每会话 `--channels` 标志）、Codex `mcp-server`（已移除）、Cursor Cloud v1 SSE（ADR-0018 已放弃）。
- Grok `[[ui.notifications.hooks]]`（hooks 已覆盖同一信号）。
