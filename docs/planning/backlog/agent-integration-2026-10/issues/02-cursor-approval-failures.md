# 02: Cursor 审批 Hook 失败时保持预期行为

Status: ready-for-agent

**What to build:** 审批服务失败不意外阻止工具，也不绕过 Cursor 原生审批。

**Blocked by:** None (can start immediately).

## Acceptance criteria

- [ ] 实测空响应、不可达、401、超时及有效允许/拒绝，修复证实的差异。
- [ ] 保留可重放回归检查，记录 CLI/IDE 各自实际验证范围。
- [ ] 按实测修订 ADR-0016 空响应假设，保留单一审批卡片。

## Context

来源：2026-10-01 用户批准的九票拆分及 Codex/Cursor 官方文档评估。遵守现有 ObservationSource、Control channel 与 Session reader 语义。
