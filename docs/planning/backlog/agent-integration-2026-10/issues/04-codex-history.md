# 04: Codex 会话历史按需分页

Status: ready-for-agent

**What to build:** 长会话先显示最近内容，按需读取更早记录。

**Blocked by:** None (can start immediately).

## Acceptance criteria

- [ ] 通过现有会话阅读入口显示最近页并加载更早内容。
- [ ] 阅读不启动或恢复会话，不修改状态、目标和已读结果。
- [ ] 不支持官方分页时保留既有只读来源，明确来源和限制。

## Context

来源：2026-10-01 用户批准的九票拆分及 Codex/Cursor 官方文档评估。遵守现有 ObservationSource、Control channel 与 Session reader 语义。
