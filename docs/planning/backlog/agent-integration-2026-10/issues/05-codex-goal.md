# 05: 展示 Codex 长任务目标进度

Status: ready-for-agent

**What to build:** 任务详情显示官方目标及进度，并明确不可用或过期状态。

**Blocked by:** None (can start immediately).

## Acceptance criteria

- [ ] 展示官方返回的目标及实际可用进度，不根据文本猜测。
- [ ] 无目标、不支持、断线或过期状态可区分。
- [ ] 只读，不创建、更新或清除目标；验证真实协议和 UI。

## Context

来源：2026-10-01 用户批准的九票拆分及 Codex/Cursor 官方文档评估。遵守现有 ObservationSource、Control channel 与 Session reader 语义。
