# 08: Cursor 云任务实时通知与续连

Status: ready-for-agent

**What to build:** 活跃云任务通过 SSE 及时更新，轮询继续负责发现和兜底。

**Blocked by:** None (can start immediately).

## Acceptance criteria

- [ ] 按 run 隔离事件 ID，断线续接，重复事件不重复通知。
- [ ] 410 过期读取权威终态，错误不误判完成；保留轮询。
- [ ] 启动不重放历史完成；验证隔离 HTTP/SSE 到快照完整路径。
- [ ] 修订 ADR-0018 暂缓 SSE 决定，记录延迟对比和真实云验收范围。

## Context

来源：2026-10-01 用户批准的九票拆分及 Codex/Cursor 官方文档评估。遵守现有 ObservationSource、Control channel 与 Session reader 语义。
