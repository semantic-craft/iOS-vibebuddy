# 02: Grok leader 扇出实测 + 托管会话恢复

**What to build:** 两个实测加一个恢复功能。(a) 实测 leader 模式：`[cli] use_leader = true` 或 `grok agent leader` 起共享进程后，用户 TUI 会话的 `session/request_permission` 是否同时送到第二个订阅 client（等价 Codex daemon 验证过的形态）；`x.ai/sessions/list` / `x.ai/sessions/changed` 能否列出 TUI 会话。若能扇出，写 ADR 决定是否让 vibebuddy 以 leader client 身份旁路挂上用户自己的会话。(b) 实测文件 hook `timeout` 有无上限（决定阻塞式 `PreToolUse` 等手机回执的"远程拒绝"可行性；SDK gate 上限 600s）。(c) 托管会话恢复：daemon 重启后用 `session/load`（`loadSession: true`，探针已确认能力位）恢复继续；恢复失败时 `grok -r <id>` 在终端续接。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] leader 实测记录（连接方式、`initialize` 能力、TUI 会话是否可见、权限请求是否扇出、答后另一端的表现）写进 Comments；结论进 ADR-0030 修正案或 wontfix。
- [ ] hook timeout 实测：`~/.grok/hooks/*.json` 里 `timeout: 1800` 的 PreToolUse 是否被截断；记录。
- [ ] `GrokACPRecovery`（元数据：sessionID、cwd、model、createdAt，0600，30 天 / 100 条）；`registerRecoverableSessions`；`prompt` 先 `restore`；失败给出可重试原因。
- [ ] 终端续接：`GrokCLI.resume(sessionID:cwd:)` 在偏好终端运行 `grok -r <id>`。
