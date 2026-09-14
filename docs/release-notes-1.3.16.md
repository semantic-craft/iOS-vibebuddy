# VibeBuddy 1.3.16 — macOS

## 中文

- Mac 首页改为 **Inbox**：集中查看需要介入、未读结果和运行中的任务；**Recap** 汇总离开期间结束的轮次，语音朗读与语音对话各有独立入口，阅读确认与手机、手表状态一致。

- Watch 新增 **Recap（回顾）**：离开一段时间后抬腕，Home 的 Results 段变为一行“N since you last read”，用数码表冠翻页查看每个会话已结束的轮次（完成或失败）、要点与时间；最后一页 **Mark all** 一次读完，Mac 与 iPhone 的未读角标和 followed 提醒一起安静。浏览不改变任何状态。Mac 以 `RecapLedger` 记账七天，每轮自带阅读标记（Mark Unread 会重新出现在 Mark all 里）。
- Mac 新增 **Continue with…**：已结束的任务行右键或详情标题栏可选择 Claude Code / Codex / Cursor 接着做；新任务表单预填该会话的目录、名称和开场白（交接文件的路径与 `Continues:` 行），你看过按 Start 才发出；同一目录有会话在忙时表单会提示并可换目录（Cursor 可开新 worktree）。写过交接文件的会话行显示 **Handoff ready**。
- `vibebuddy-mcp` 新增只读命令 `facts <key>`（MCP 工具 `vibebuddy_handoff_facts`）：打印一个会话的交接头四行与 VibeBuddy 记录的事实——已结束轮次、当前 git HEAD 与改动、改过的文件、跑过的命令与退出码、观测覆盖范围与数据时效。`vibebuddy-handoff` 技能写交接前先调用它；`vibebuddy-history` 读方用它比对漂移。

## English

- **Inbox and Recap on the Mac** bring pending tasks, unread results, working sessions and ended rounds into one workflow, with separate read-aloud and voice-conversation controls and shared read confirmation across devices.

- **Recap on the Watch**: one row says how many rounds ended since you last read; turn the Digital Crown through one page per ended round (completed or failed) and finish with **Mark all**, which quiets the Mac and iPhone badges and followed-completion reminders together. Viewing changes nothing; the Mac keeps a seven-day `RecapLedger` with a per-round read mark.
- **Continue with…** on the Mac: a finished task's context menu or title bar offers Claude Code, Codex or Cursor; the New task sheet opens prefilled with the session's checkout, a name and a first prompt that points at the handoff document's path (`Read <path>, then continue.` + `Continues: vibebuddy://session/<key>`). You review and press Start. Rows with a handoff document show **Handoff ready**; the sheet warns when other sessions work in that folder.
- `vibebuddy-mcp facts <key>` (`vibebuddy_handoff_facts`): a read-only Markdown block of what the Mac recorded for one session — rounds ended, live git HEAD and dirty paths, files edited, commands with exit codes, a coverage line and a data-freshness line — for the top of a handoff note and for the receiver's drift check.

## 范围与限制 / Scope and limits

- Continue with… 只在 Mac；iPhone / Watch 的入口、跨机交接、事实的 LLM 摘要不在本版。
- 重启后仍在：最近目录与每个会话观察到的 checkout（`recent-directories.json`）、谁接了谁（`continuations.json`），都是仅本人可读、七天保留的本地文件；`facts` 会打印接收方的 `Continues:` 行。目录不确定时表单留空让你选，不再猜。
- Codex 从 agent worktree 接续时，Mac 只在该 thread 自己是 workspace-write 策略时，把交接文件所在的 `.scratch/<feature>/` 追加为可写目录（对该任务后续轮次持续有效），其余限制不变；其他策略不动。开场白里的提醒只是兜底。
- 交接派发核对已发现的文件及来源；改选目录后更新提示。工具事实按实际 agent 身份归属，无法确认身份的旧记录明确省略；仅成功编辑计入已改文件，交接文件原地更新也会及时刷新。
- `facts` 的命令与退出码来自 Claude 系 hook 与 Codex app-server；Cursor ACP 与 rollout 只能报告工具名，输出会明写。
- Recap 的真机分页手感、`.success` 触感与 Double Tap 未在实体设备验收。
- Continue with… is Mac-only in this release. Recent directories, each session's observed checkout and continuation lineage now survive a restart (owner-only local files, seven days); a Codex receiver started from a worktree gets the handoff's `.scratch/<feature>/` as an extra writable root only when its own policy is workspace-write. `facts` carries command text and exit codes for Claude-shaped hooks and the Codex app-server only. Recap's on-device feel remains unverified.
