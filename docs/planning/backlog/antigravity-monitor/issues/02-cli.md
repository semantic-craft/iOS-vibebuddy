# 02: CLI 自动发现、等待与完整结果

Status: ready-for-agent

Parent: [SPEC](../SPEC.md) · [PRD](../PRD.md)

Blocked by: None

## What to build

原 CLI 启动任务自动进入现有列表，真实状态与完整结果进入阅读和通知链路。

## Acceptance criteria

- [ ] 现代 hooks 与原生日志匹配同一身份，来源标记 CLI
- [ ] 问题/权限等待与结束区别；取消不成功；失联不结束
- [ ] full 正文用于 Mac 阅读及手机完成结果，首见历史不通知
