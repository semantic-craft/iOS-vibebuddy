# 03: Codex 高负载与断线后的可靠观测

Status: ready-for-agent

**What to build:** 繁忙和断线恢复后，任务状态与完成通知仍准确，事件缓冲有界。

**Blocked by:** None (can start immediately).

## Acceptance criteria

- [ ] 抑制不消费的通知，保留生命周期、完整结果、usage 与审批。
- [ ] 溢出和重连显式重同步，关键事件不静默丢失；控制写请求不盲目重试。
- [ ] 回放验证不重复审批或完成，记录缓冲/内存和延迟对比。

## Context

来源：2026-10-01 用户批准的九票拆分及 Codex/Cursor 官方文档评估。遵守现有 ObservationSource、Control channel 与 Session reader 语义。
