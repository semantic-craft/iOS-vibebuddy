# 09: Cursor 持久会话断开后持续可见

Status: ready-for-agent

**What to build:** 终端断开或重连时持久任务仍可观测，控制动作符合实际能力。

**Blocked by:** None (can start immediately).

## Acceptance criteria

- [ ] 用持久 CLI 会话验证断开、继续运行、重连和完成的观测。
- [ ] 必要时补齐只读发现；不接管外部会话或扩展 ACP 控制承诺。
- [ ] 状态连续、无重复完成通知；版本不支持时明确说明。

## Context

来源：2026-10-01 用户批准的九票拆分及 Codex/Cursor 官方文档评估。遵守现有 ObservationSource、Control channel 与 Session reader 语义。
