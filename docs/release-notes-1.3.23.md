# VibeBuddy 1.3.23 — macOS

- 修复 Claude / Cursor 问答状态：只有仍在等待回复的原生请求可以回答；从对话记录恢复的问题、已超时的问题显示为只读。
- 普通通知不再覆盖正在等待的问答或审批状态；迟到的旧请求清理不会影响新问题。
- 修复 Codex 会话首次发现晚于原生任务开始时的完成正文恢复；同一轮中的继续指令和多个最终消息按原生轮次对应。

- Claude 空闲提醒不再丢失已完成任务的状态。

## English

- Keep Claude / Cursor questions answerable only while the native request is waiting. Transcript-inferred and timed-out questions are read-only.
- Preserve active question and approval state across generic notifications, and prevent stale cleanup from disabling newer questions.
- Recover Codex completion bodies when session discovery follows the native turn start, including steering and multiple final messages within that turn.

- Preserve completed task state when Claude sends an idle reminder.

Mac build 38. This release updates the Mac companion only. Previously stored legacy completions without an exact turn mapping remain unavailable.
