# 07: Cursor 托管会话可靠使用已有 MCP

Status: ready-for-agent

**What to build:** 项目级和用户级 MCP 在托管 Cursor 会话中可发现且可调用。

**Blocked by:** None (can start immediately).

## Acceptance criteria

- [ ] 隔离验证项目和用户 MCP 自动加载，必要时修复启动路径。
- [ ] 不改用户凭据；团队 MCP 不支持边界明确。
- [ ] 保留托管会话恢复、权限和单一所有者语义。

## Context

来源：2026-10-01 用户批准的九票拆分及 Codex/Cursor 官方文档评估。遵守现有 ObservationSource、Control channel 与 Session reader 语义。
