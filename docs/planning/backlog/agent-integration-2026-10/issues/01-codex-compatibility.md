# 01: Codex 新版事件兼容与接入诊断

Status: ready-for-agent

**What to build:** 新版真实事件正确驱动状态、工具和完成结果，诊断区分版本未知、服务未连接与正常观测。

**Blocked by:** None (can start immediately).

## Acceptance criteria

- [ ] 用当前安装版本真实事件回放验证进度、工具、usage 和完成；仅认证已验证格式。
- [ ] 共享服务不可用时仍输出静态协议审计结果；独立报告运行连接状态。
- [ ] 不启动生产共享服务，不把 CLI 版本当作 Desktop 生产者版本。

## Context

来源：2026-10-01 用户批准的九票拆分及 Codex/Cursor 官方文档评估。遵守现有 ObservationSource、Control channel 与 Session reader 语义。
