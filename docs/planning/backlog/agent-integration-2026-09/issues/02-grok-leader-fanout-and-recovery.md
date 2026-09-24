# 02: Grok leader 扇出实测 + 托管会话恢复

**What to build:** 两个实测加一个恢复功能。(a) 实测 leader 模式：`[cli] use_leader = true` 或 `grok agent leader` 起共享进程后，用户 TUI 会话的 `session/request_permission` 是否同时送到第二个订阅 client（等价 Codex daemon 验证过的形态）；`x.ai/sessions/list` / `x.ai/sessions/changed` 能否列出 TUI 会话。若能扇出，写 ADR 决定是否让 vibebuddy 以 leader client 身份旁路挂上用户自己的会话。(b) 实测文件 hook `timeout` 有无上限（决定阻塞式 `PreToolUse` 等手机回执的"远程拒绝"可行性；SDK gate 上限 600s）。(c) 托管会话恢复：daemon 重启后用 `session/load`（`loadSession: true`，探针已确认能力位）恢复继续；恢复失败时 `grok -r <id>` 在终端续接。

**Blocked by:** 01

**Status:** done（PR 见 README 行）

- [x] leader 实测记录（连接方式、`initialize` 能力、TUI 会话是否可见、权限请求是否扇出、答后另一端的表现）写进 Comments；结论进 ADR-0030 修正案或 wontfix。
- [x] hook timeout 实测：`~/.grok/hooks/*.json` 里 `timeout: 1800` 的 PreToolUse 是否被截断；记录。
- [x] `GrokACPRecovery`（元数据：sessionID、cwd、model、createdAt，0600，30 天 / 100 条）；`registerRecoverableSessions`；`prompt` 先 `restore`；失败给出可重试原因。
- [x] 终端续接：`GrokCLI.resume(sessionID:cwd:)` 在偏好终端运行 `grok -r <id>`（实际用 `grok --resume=<id>`，与 `-r` 同义；带等号的写法不会把 id 当成提示词）。

## Comments

2026-09-24，grok 1.0.41。全部在临时 `GROK_HOME` / 临时 HOME 里做，你的 `~/.grok` 没动。

**(a) leader 扇出**（`[cli] use_leader = true`，`[ui] permission_mode = "default"`，HOME 也换成空目录，否则 Grok 会导入 `~/.claude/settings.json` 的放行规则，`touch` 之类直接执行、不弹权限）

- 连接：TUI 启动时自己拉起 `grok agent leader --no-exit-on-disconnect --relay-on-demand`，socket 默认在 Grok 主目录（`<GROK_HOME>/leader.sock`；scratchpad 路径太长时报 `path must be shorter than SUN_LEN`，所以测试用了 `--leader-socket /tmp/…`）。TUI 关掉后 leader 不退出。第二个客户端：`grok agent --leader --leader-socket <sock> stdio`。
- `initialize`：`protocolVersion 1`，`agentCapabilities.loadSession = true`，`sessionCapabilities` 有 `list` / `resume` / `close`，`authMethods` 有 `cached_token`；`_meta` 里有 `x.ai/hooks`（`blockingEvents: pre_tool_use, stop, subagent_stop`）。
- TUI 会话可见：标准 `session/list` 和 `_x.ai/sessions/list` 都列出 TUI 的会话（`x.ai/sessions/list` 不带下划线是 Method not found）；之后还会收到 `_x.ai/sessions/changed` 推送。
- 权限扇出：第二个客户端 `session/load` TUI 的会话后，TUI 发起 `curl` 时两边同时出现提示，第二个客户端收到 `session/request_permission`（选项 `enable-always-approve` / `allow-always-command` / `allow-once` / `reject-once` / `reject-always-command`），外加 `_x.ai/session_notification: pending_interaction`。
- 答后另一端：在 TUI 里点「Yes, proceed」→ 第二个客户端收到 `interaction_resolved`（请求本身不单独取消）。第二个客户端先答 `allow-once`（延迟 4 s）→ TUI 的提示关闭、工具执行、回合正常结束。**leader 客户端的回答是权威的**，这是目前唯一能从外部批准终端 Grok 会话的通道。
- 关掉 TUI（`kill`）后：回合在 leader 里继续跑（前台命令被转成后台任务后完成），hook 继续触发（`post_tool_use` +11 s、`stop` +28 s），**不触发 `SessionEnd`**，而 `active_sessions.json` 已清空。AI-03 因此加了 leader 守卫：Grok 主目录里有能连上的 `leader*.sock` 时不做名册兜底。
- 结论写进 ADR-0030 修正案 1：可行，但这次不做（`use_leader` 默认关；挂上去等于在你自己的会话上多一个审批人、先答者生效；托管会话仍用 `--no-leader`）。要做的话另开票，做成只对已开 leader 的用户生效的选项。

**(b) hook timeout**：`PreToolUse` 文件 hook、`timeout: 1800`、脚本 sleep 后输出 deny。
- sleep 700：hook 运行 758 s 后返回 deny，工具被拦下（`Hook denied: probe denied after 700 s`）——没有 600 s 上限。
- sleep 1790：在 1 800 s 被杀（`timed out after 1800000ms`，elapsed 1 800 895 ms），fail-open，命令照常执行。
- 所以阻塞式 `PreToolUse` 等手机回执最长可以等 `timeout` 那么久（至少 30 分钟），但 hook 的 `allow` 仍然只是「不拦」，答不了 Grok 自己的提示，所以这只能延长**远程拒绝**；现有 30 s 审批门不变。

**(c) 托管会话恢复**（隔离 `vibebuddyd` :18795，真实 grok）
- `/dispatch` 起 Grok 会话（回复 "one"）→ `<support>/grok-acp/<id>.json`（0600）+ `.lock` 租约。
- `SIGTERM` 重启 daemon（同一 HOME）：旧的 `grok agent` 子进程随 stdin 关闭退出；新 daemon 的快照里该行是「可恢复」（`controlChannel: none`、`cursorACPRecoverable: true`）。
- `/answer intent=continue`「上次你回复的是哪个词？说两遍」→ 起新的 `grok agent -m grok-4.7 --no-leader stdio` 并 `session/load` → 行回到 `acp`，回答 "one one"（记得重启前的对话）。
- 失败路径：再重启、把会话目录挪走 → `/answer` 返回 `failed`，理由 `Couldn't reload this Grok session (Path not found.). Open it on the Mac to continue it in a terminal (grok --resume).`，行上保留可重试的原因，没有残留 grok 进程；把目录放回后再发一次，成功（"three"）。
- 终端续接：Mac 上「打开」这一行（跳转动作，手机上的跳转也走这里）在偏好终端运行 `cd <dir> && grok --resume=<id>`，成功后删掉恢复记录，会话交给终端（hook 观察）。命令拼接与 id 校验、打开后删记录由单元测试覆盖；**没有在真机上弹终端窗口**（会在你的桌面上开窗）。`grok --resume=<id>` 本身在 tmux 里实测能带历史打开会话。
