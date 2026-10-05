# iOS-vibebuddy：Agent可用性实施规格

<!-- agent-infra:20261005:spec:iOS-vibebuddy -->

**Status:** implementation-authorized；执行路线为逐票 `/implement`，按下列阻塞关系推进。

## Problem Statement

现有实现、候选、生产状态及剩余验收分散，容易重复工作或把测试通过当成实际交付。本项目只完成下列已确定切片，不承担跨仓调度平台。

## Solution

复用本项目现有入口与唯一owner，补齐可观察行为、可靠失败和恢复；在正式票中维护状态，保留原有已完成成果。

## User Stories

1. As a 项目使用者, I want Agent能看到逐检查结果、目标端口/数据目录/共享App影响与安全接续，实际安装尊重共享App占用。 so that 实际结果可核验并可安全接续。

## Implementation Decisions

保留本项目领域模型、输出/退出码、版本和权限合同；只在现有边界加小切片，不建统一大状态机。隔离工作区保护并行修改，领取前检查claim。按原owner或明确指定的唯一owner实施。

## Testing Decisions

从现有最高CLI/MCP/文件或app接口检查外部行为；每票分别提供合成、真实入口、产品验收证据。测试绿不等于部署或用户接受。文档发布只做差异、链接与隐私检查，不运行全库测试。

## Out of Scope

不重开已完成工单，不以发布票据启动未授权数据操作，不增加通用框架或新调度层。原件与并行生产保留；Recents、已完成同步及零候选lint均不属于本规格。

## Tickets and blocking edges

- [23](issues/01-agent-contract.md) — blocked by: none；start: 待总协调明确指定唯一工程 owner，发布不等于已领取。指定 owner 开工前检查既有 writer 与共享 App 的 peer 验收；peer 使用中不替换共享 App，继续独立工作并记录未安装。计划与检查不启动生产端口、不读取私人 history、不启动第二个生产菜单栏实例。实际安装仅在具体任务范围内、peer 检查允许后执行。

## Further Notes

用户于2026-10-05明确授权推进实现与发布工单。此规格不是新账户/生产/删除授权；未决产品决定与条件性需求仍在各票中具名保留。代码、部署与用户产物分别完成后才关闭相应票。
