# 01: 把工程检查与安装计划交给 Agent

<!-- agent-infra:20261005:23 -->

Status: ready-for-human

Owner: unassigned for the remaining designated product acceptance.
Implementation owner: VibeBuddy23 coordinator task `01a1032c-8835-7361-b7c8-13a2836af030`
completed engineering delivery in PR #350. The old implementation branch is
historical evidence, not an active claim.

**Delivery:** implementation and scoped engineering acceptance merged through
[PR #350](https://github.com/semantic-craft/iOS-vibebuddy/pull/350), merge
`430c29390078ec42025ba2a67f8e3ca5c33e3587`, reviewed head
`3c3c76edb0109e3aa8d6e02a2de8ea6a8f28ecc0`. Independent AGY Gemini verdict:
MERGE. No production installation, device/voice acceptance or owner acceptance
is claimed. The later designated installation and its real receipt remain
unverified; retain this ticket for that product acceptance boundary. See
[engineering contract QA](../../../../qa/agent-engineering-contract-20261005.md).

批次引用：AI-20261005-23；本功能内编号01。

## Parent / Spec

[本项目实施规格](../PRD.md)

## What to build

Agent能看到逐检查结果、目标端口/数据目录/共享App影响与安全接续，实际安装尊重共享App占用。

## Owner and start condition

待总协调明确指定唯一工程 owner，发布不等于已领取。指定 owner 开工前检查既有 writer 与共享 App 的 peer 验收；peer 使用中不替换共享 App，继续独立工作并记录未安装。计划与检查不启动生产端口、不读取私人 history、不启动第二个生产菜单栏实例。实际安装仅在具体任务范围内、peer 检查允许后执行。

## Current evidence / duplication check

复用 tools/check.py 与现有 results.json、verify-vibebuddy 隔离验收和 docs/sparkle-setup.md 的共享App检查；不新造第二套检查器。status/facts已有只读MCP；GEM/IOSP/GROK/SET既有待验票不重开。

在本项目现有票与PR基础上补剩余缺口，已closed/done成果保持原状态；发布前已查当前issue/PR及适用本地tracker，领取时再查新claim和代码。

## Acceptance criteria

- [ ] Synthetic：保留JSON-RPC framing/isError与CLI0/1/2；安装plan不写Application/端口/登录配置，skip/limitation可解析。
- [ ] Real service / actual entry：隔离工程检查输出可消费；安装前只读识别共享App peer，占用时继续独立工作且保留未安装状态。
- [ ] Product：后续指定安装从计划到回执可核验；实机/手机/语音未验不能标通过，纯读status不强加dry-run。
- [ ] 回填受验提交、实际命令/结果、产物身份/hash、未运行项及不含个人home路径的证据指针；完整本地证据由owner保留。代码、测试、合并、部署、产品验收和用户接受分别报告。

## Blocked by

- None（无技术票前置；仍须满足上述 Owner and start condition）。

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
