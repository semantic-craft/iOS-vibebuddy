# 03: Grok status line 转发 + 活跃会话名册

**What to build:** 与 Claude 同构的 `[ui.status_line] type = "command"` 包装脚本（保留用户原有 command，复制 stdin JSON 到 daemon `/statusline?agent=grok`），填 `context_window.*`、`cost.total_cost_usd`、`workspace.repo.*`、`worktree.*`、`effort.level`、`turn.started_at_ms`；`~/.grok/active_sessions.json`（`cli.session_registry`：session_id、pid、cwd、opened_at）作为存活兜底：名册里没有的会话不再当 working。

**Blocked by:** None

**Status:** ready-for-agent

- [ ] `install-grok-hooks.py --statusline` 写 `[ui.status_line]`，`--uninstall` 还原；Grok 读该表只在启动时。
- [ ] `StatusLineSample` 解 Grok 字段差异（`workspace.repo_root` 无 `project_dir`；`transcript_path` 指 `updates.jsonl`；缺字段不填零）。
- [ ] `GrokActiveSessions` 读名册（mtime 变化时），pid 存活校验。
- [ ] 验收：真实 grok 会话行出现上下文 % 与成本；关掉 TUI 后名册移除、行离开 working。
