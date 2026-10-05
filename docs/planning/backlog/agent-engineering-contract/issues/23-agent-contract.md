# 23: 把工程检查与安装计划交给 Agent

<!-- agent-infra:20261005:23 -->

**Status:** ready-for-agent

## Parent / Spec

[本项目实施规格](../PRD.md)

## What to build

Agent能看到逐检查结果、目标端口/数据目录/共享App影响与安全接续，实际安装尊重共享App占用。

## Owner and start condition

待协调者指定唯一实现 owner；本票发布不构成已领取

指定唯一工程owner；先检查共享App的peer验收，不替换被使用的App。

## Current evidence / duplication check

status/facts已有只读MCP；check results.json已实现；GEM/IOSP/GROK/SET既有待验票不重开。

在本项目现有票与PR基础上补剩余缺口，已closed/done成果保持原状态；发布前已查当前issue/PR及适用本地tracker，领取时再查新claim和代码。

## Acceptance criteria

- [ ] Synthetic：保留JSON-RPC framing/isError与CLI0/1/2；安装plan不写Application/端口/登录配置，skip/limitation可解析。
- [ ] Real service / actual entry：隔离工程检查输出可消费；安装前只读识别共享App peer，占用时继续独立工作且保留未安装状态。
- [ ] Product：后续指定安装从计划到回执可核验；实机/手机/语音未验不能标通过，纯读status不强加dry-run。
- [ ] 回填受验提交、实际命令/结果、产物身份/hash、证据位置与未运行项。代码、测试、合并、部署、产品验收和用户接受分别报告。

## Blocked by

- None（无技术票前置；仍须满足下方Start条件）。

## Implementation route

按本项目逐票 `/implement`：复用现有最高外部接口，以适用的 `/tdd` 验证行为，完成 `/code-review`，走项目正常提交/PR/部署路径。不同仓库不汇入一个integration branch，不新增多层Agent。只有满足本票前置条件的工作可开始；新owner必须先查现有writer并声明范围。

## Scope / non-goals / permissions

正式工单使用仓内tracked backlog。实现按任务目标授权推进，但计划验证不启动生产端口、不读取私人history、不替换被peer使用的共享App。

用户已明确批准把此批工作推进实现及发布工单。目标范围内正常工程交付不重复逐步确认；这一授权不扩大真实账户、计费、数据删除、云权限或具体生产变更范围。旧草稿的“未发布/禁止commit”终点已被本次授权替代，具体有效安全限制仍需遵守。

保持项目既有JSON/MCP与exit合同；strict dry-run披露reads/network/unknown且无意图副作用；unknown先按原身份对账，不盲重放。保护原件、脏树和并行writer，不引入通用状态机或框架。

## Rollback

使用项目既有安装/版本恢复；不终止其他会话的实机验收。

## Open decisions

无新增产品决定；技术事实由接手者核实。

## Evidence handling

本票及关联PR为此切片状态源；本地/运行证据由owner保留，公开工单不包含个人绝对路径、私有材料或秘密。复制测试通过数不能替代对应版本的真实服务/产品验收。总体HTML只提供这些正式票的入口。
