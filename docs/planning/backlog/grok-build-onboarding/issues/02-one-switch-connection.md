# GROK-02：Grok Build 一键接入与状态反馈

Status: ready-for-agent
Priority: P1
Date: 2026-10-02
Parent: GROK-01
Blocked by: None (can start immediately)

## What to build

在 Agent 接入中开启 Grok Build 监控后自动配置观测 hooks，并在同一处看到实际状态、必要重载步骤和可重试的失败原因。账户额度保持独立。关闭监控后重启不重新开启，已接入用户保持接入，主动卸载意图优先保留。

## Acceptance criteria

- [ ] 开关触发配置，无需到诊断页或使用安装命令；配置失败有原因和重试。
- [ ] 配置成功但没有真实事件时不声称已连接；已有运行会话给重载步骤，没有会话说明等待新会话。
- [ ] 收到真实 Grok 事件后状态自动更新；关闭后停止终端 Grok 的新增监控与提醒，重启保持关闭。
- [ ] 额度开关说明准确，并为尚未接入用户提供直接入口，不将已有额度偏好自动迁移为监控授权。
- [ ] 保留其他 hooks、Grok 权限模式、自定义 Grok home、已有接入和卸载记录；不引入审批 gate。
- [ ] 完成受影响构建、关键回归验证和隔离环境中的真实事件/UI 验收，报告无法运行的具体项目。
