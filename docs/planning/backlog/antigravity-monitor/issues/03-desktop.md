# 03: 桌面自动发现与步骤状态

Status: ready-for-agent

Parent: [SPEC](../SPEC.md) · [PRD](../PRD.md)

Blocked by: 02-cli

## What to build

桌面已有和新建任务由本地 RPC 观察，三端使用相同状态和阅读链路。

## Acceptance criteria

- [ ] 同用户 loopback 发现、列表与步骤真实读取，无凭据日志
- [ ] WAITING 优先 RUNNING，取消清除等待，断线恢复不重复会话
- [ ] 正文和来源可辨；账号归属不可证实时不冒充桌面额度
