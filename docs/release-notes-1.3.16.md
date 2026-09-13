# VibeBuddy 1.3.16 — macOS（草稿，随下一次发布定稿）

## 中文

- Watch 新增 **Recap（回顾）**：离开一段时间后抬腕，Home 的 Results 段变为一行“N since you last read”，用数码表冠翻页查看每个会话已结束的轮次（完成或失败）、要点与时间；最后一页 **Mark all** 一次读完，Mac 与 iPhone 的未读角标和 followed 提醒一起安静。浏览不改变任何状态。Mac 以 `RecapLedger` 记账七天，每轮自带阅读标记（Mark Unread 会重新出现在 Mark all 里）。
- Mac 新增 **Continue with…**：已结束的任务行右键或详情标题栏可选择 Claude Code / Codex / Cursor 接着做；新任务表单预填该会话的目录、名称和开场白（交接文件的路径与 `Continues:` 行），你看过按 Start 才发出；同一目录有会话在忙时表单会提示并可换目录（Cursor 可开新 worktree）。写过交接文件的会话行显示 **Handoff ready**。
- `vibebuddy-mcp` 新增只读命令 `facts <key>`（MCP 工具 `vibebuddy_handoff_facts`）：打印一个会话的交接头四行与 VibeBuddy 记录的事实——已结束轮次、当前 git HEAD 与改动、改过的文件、跑过的命令与退出码、观测覆盖范围与数据时效。`vibebuddy-handoff` 技能写交接前先调用它；`vibebuddy-history` 读方用它比对漂移。

## English

- **Recap on the Watch**: one row says how many rounds ended since you last read; turn the Digital Crown through one page per ended round (completed or failed) and finish with **Mark all**, which quiets the Mac and iPhone badges and followed-completion reminders together. Viewing changes nothing; the Mac keeps a seven-day `RecapLedger` with a per-round read mark.
- **Continue with…** on the Mac: a finished task's context menu or title bar offers Claude Code, Codex or Cursor; the New task sheet opens prefilled with the session's checkout, a name and a first prompt that points at the handoff document's path (`Read <path>, then continue.` + `Continues: vibebuddy://session/<key>`). You review and press Start. Rows with a handoff document show **Handoff ready**; the sheet warns when other sessions work in that folder.
- `vibebuddy-mcp facts <key>` (`vibebuddy_handoff_facts`): a read-only Markdown block of what the Mac recorded for one session — rounds ended, live git HEAD and dirty paths, files edited, commands with exit codes, a coverage line and a data-freshness line — for the top of a handoff note and for the receiver's drift check.

## 范围与限制 / Scope and limits

- Continue with… 只在 Mac；iPhone / Watch 的入口、跨机交接、事实的 LLM 摘要不在本版。血缘（谁接了谁）只保存在运行中的 App 内。Codex 在 agent worktree 里接续时，`.scratch`（指向主 checkout 的符号链接）可能在其沙箱可写范围之外，需要读方按提示处理。
- `facts` 的命令与退出码来自 Claude 系 hook 与 Codex app-server；Cursor ACP 与 rollout 只能报告工具名，输出会明写。
- Recap 的真机分页手感、`.success` 触感与 Double Tap 未在实体设备验收。
- Continue with… is Mac-only in this release; lineage lives in the running app. `facts` carries command text and exit codes for Claude-shaped hooks and the Codex app-server only. Recap's on-device feel remains unverified.
