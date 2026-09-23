# 05: Claude 后台会话改读 `claude agents --json`

**What to build:** `ClaudeBackgroundSessions` 停止读 `~/.claude/jobs/<id>/state.json`（官方声明"not a stable interface"），改用 `claude agents --json --all`（官方"the supported way to read session state from outside Claude Code"）；字段 `state` (working/blocked/done/failed/stopped)、`status`、`waitingFor`（permission prompt / input needed / sandbox request / worker request / dialog open）、`sessionId`、`name`、`cwd`、`pid`。

**Blocked by:** None

**Status:** ready-for-agent

- [ ] 子进程按需运行（不在每次 snapshot 上），结果缓存并按 mtime/间隔刷新。
- [ ] `waitingFor` 映射 needsResponse 的 waitKind 展示（不改三态权威：hooks 仍是权威）。
- [ ] 测试用本机 `claude agents --json` 真实样本作夹具。

## Comments

- 2026-09-23 实现细节（对照官方文档与同类项目后拍板）：
  - 官方 agent-view 文档："`claude agents --json` is the supported way to read session state from outside Claude Code… Poll `claude agents --json --all`"；`~/.claude/jobs/<id>/` "not a stable interface"。
  - 同类：maddada/Ghostex（`claude_background.rs`，带 `HOME` / `CLAUDE_CONFIG_DIR` 与超时）、Facets-cloud/flow（`background.go`，只取 `kind:"background"`，30 s 超时，实测一次约 10 s）、dob323/session-kit（记录部分版本只返回 7 个字段）。
  - **做法**：后台线程运行，超时 ≥ 15 s；结果缓存，按间隔或收到 hook 事件时刷新，绝不在每次 snapshot 上调用；透传 `HOME` 与 `CLAUDE_CONFIG_DIR`；字段按出现解码（`state`、`waitingFor` 可能缺）；`~/.claude/jobs` 只作旧版 CLI 的回退并记一条警告；hooks 仍是当前状态的权威。
