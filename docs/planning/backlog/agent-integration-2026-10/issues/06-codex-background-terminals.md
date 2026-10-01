# 06: 展示 Codex 后台终端

Status: ready-for-agent

**What to build:** 任务详情只读展示该线程后台终端及运行信息。

**Blocked by:** None (can start immediately).

## Acceptance criteria

- [ ] 仅展示所选线程后台终端，切换任务不残留旧数据。
- [ ] 不支持和查询失败明确可见，不提供终止操作。
- [ ] 使用当前版本实验协议验证；不执行 spawn/terminate/clean。

## Context

来源：2026-10-01 用户批准的九票拆分及 Codex/Cursor 官方文档评估。遵守现有 ObservationSource、Control channel 与 Session reader 语义。
