# 03: Grok status line 转发 + 活跃会话名册

**What to build:** 与 Claude 同构的 `[ui.status_line] type = "command"` 包装脚本（保留用户原有 command，复制 stdin JSON 到 daemon `/statusline?agent=grok`），填 `context_window.*`、`cost.total_cost_usd`、`workspace.repo.*`、`worktree.*`、`effort.level`、`turn.started_at_ms`；`~/.grok/active_sessions.json`（`cli.session_registry`：session_id、pid、cwd、opened_at）作为存活兜底：名册里没有的会话不再当 working。

**Blocked by:** None

**Status:** done（#298）

- [x] Swift `HookInstaller`（`GrokHooks`）加 status line 选项，写 `[ui.status_line]`，卸载时还原；Grok 读该表只在启动时。
- [x] `StatusLineSample` 解 Grok 字段差异（`workspace.repo_root` 无 `project_dir`；`transcript_path` 指 `updates.jsonl`；缺字段不填零）。
- [x] `GrokActiveSessions` 读名册（mtime 变化时），pid 存活校验。
- [x] 验收：真实 grok 会话行出现上下文 % 与成本；关掉 TUI 后名册移除、行离开 working。

## Comments

2026-09-24（grok 1.0.41，临时 HOME + 隔离 `vibebuddyd` :18793，真实 `~/.grok/config.toml` 未动）：

- 安装：`install --agent grok` 同时包装 `[ui.status_line]`（只按文本改这一张表；`builtin`、内联表、点号键、多行值一律不动并说明）；`--statusline --agent grok` 只装状态行。卸载按字节还原。
- 实测 Grok 会杀掉状态行脚本留下的后台进程（分离的子进程从未执行），所以 Grok 分支的包装脚本要等 curl（最多 1 s）结束再退出；Claude 分支不变。
- 真实 TUI：Grok 行显示上下文 21 519 / 500 000、成本 $0.0382、effort xhigh，观测来源 hook + statusline + transcript。`used_percentage` 是取整的整数，所以用 `context_tokens`；成本在第一次计价前缺席，按未知处理。
- 名册：TUI 启动即登记自身 pid；正常退出（SIGHUP）清空；`kill -9` 留下死 pid 的条目，直到下一个 grok 写文件。正常关闭时 `SessionEnd` hook 约 1 s 移除行；`kill -9`（hook 不可能触发）后 16 s，下一次 sweep 由名册兜底结束该行（日志 `sessionEnd`，来源 `recovery`；当时的构建另记了一条 `grokSessionClosed`，评审后去掉）。
- 只结束"见过在名册里、且当时登记的进程已退出"的会话；条目消失但进程还在（名册被改写）交给 hook；名册关闭、别的 `GROK_HOME`、重启后恢复的行都不会被误结束（日志记 `sessionEnd`，来源 `recovery`）。
- leader 模式（AI-02 实测）：TUI 关掉后回合在 leader 里继续跑、hook 继续触发、不发 `SessionEnd`，名册却已清空。所以 Grok 主目录里有能连上的 `leader*.sock` 时不做名册兜底；`--leader-socket` 指到别处的 leader 看不到。
- 未做：`workspace.repo.*`、`turn.started_at_ms` 没有对应的会话字段，未映射；Settings 诊断里没有加 Grok 状态行行（安装/修复已自动接上）。
