# VibeBuddy 1.3.29 — macOS

- 修复 1.3.28 解开 Cursor 卡顿后暴露的空闲 CPU 偏高（看板打开时 50–65%）：History 库过去对正在被 agent 追加的转录文件每分钟整个重新索引多次，现在同一文件 15 秒内最多索引一次，变更不丢只延后。
- 推给 iPhone 的快照改为每 300 毫秒最多一帧：一次事件突发只发首帧和最后一帧，手机看到的仍是最终状态。
- 修正 Cursor 会话信息合并：明细里明确为空的字段（如没有工作区的对话）不再被旧的头部信息回填。

包含 1.3.28 的全部修复。iPhone 对应版本仍为 iOS 1.3.25（55），无需更新。

## English

- Fixes the idle CPU that 1.3.28 exposed once the Cursor stall was gone (50–65% with the dashboard open): the History library used to re-index a transcript an agent is appending to several times a minute, whole; a file is now indexed at most once per 15 s, with changes deferred rather than dropped.
- Snapshots pushed to the phone are delivered at most once per 300 ms: a burst of events sends its first and its last frame, and the phone still sees the final state.
- Cursor conversation facts merge per key again: a field the detail record carries as empty (a chat with no workspace) is no longer back-filled from the older header.

Mac build 47. Includes all fixes from Mac 1.3.28. The accompanying iPhone release remains iOS 1.3.25 (55); no phone update is needed.
