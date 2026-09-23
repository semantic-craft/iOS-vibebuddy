# 05: Claude 后台会话改读 `claude agents --json`

**What to build:** `ClaudeBackgroundSessions` 停止读 `~/.claude/jobs/<id>/state.json`（官方声明"not a stable interface"），改用 `claude agents --json --all`（官方"the supported way to read session state from outside Claude Code"）；字段 `state` (working/blocked/done/failed/stopped)、`status`、`waitingFor`（permission prompt / input needed / sandbox request / worker request / dialog open）、`sessionId`、`name`、`cwd`、`pid`。

**Blocked by:** None

**Status:** ready-for-agent

- [ ] 子进程按需运行（不在每次 snapshot 上），结果缓存并按 mtime/间隔刷新。
- [ ] `waitingFor` 映射 needsResponse 的 waitKind 展示（不改三态权威：hooks 仍是权威）。
- [ ] 测试用本机 `claude agents --json` 真实样本作夹具。
