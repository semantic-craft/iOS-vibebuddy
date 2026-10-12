# 暂不实施计划关闭 — 2026-10-12

基线：`9a2a2890c81b8a37c82a795d2a41052ed079afaf`（PR #362 后 main）。用户明确关闭 Mac App Store 09–18 十票和 Web 接入设计票，保留有效设计与研究；SQLite 迁移仅留观察项。

结果：11 票以**用户决定暂不做**关闭，不是实现完成或验收通过；SQLite 票转为非施工观察记录。原 21 票经两次收尾后，正式 `issues/` 开放施工票为 0。其他无正式票的建议/观察仍按原范围保留，不宣称所有产品功能或验收已完成。

## 关闭清单

<a id="mac-app-store-09"></a>

- **09 — 商店版启动后可与 iPhone Pairing**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-09) 保留。

<a id="mac-app-store-10"></a>

- **10 — 商店版重启后保留 Pairing 与应用数据**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-10) 保留。

<a id="mac-app-store-11"></a>

- **11 — 外部目录授权可记住、撤销并恢复**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-11) 保留。

<a id="mac-app-store-12"></a>

- **12 — 从 Settings 安装 Claude Hook 并收到真实事件**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-12) 保留。

<a id="mac-app-store-13"></a>

- **13 — 关卡：真实 Claude 任务从手机批准、拒绝与回答**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-13) 保留。

<a id="mac-app-store-14"></a>

- **14 — Codex CLI 可从手机放行，其它 CLI 可观察**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-14) 保留。

<a id="mac-app-store-15"></a>

- **15 — Codex Desktop 任务进度可观察**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-15) 保留。

<a id="mac-app-store-16"></a>

- **16 — 商店界面只提供可执行能力，用量与 Jump 如实反馈**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-16) 保留。

<a id="mac-app-store-17"></a>

- **17 — 两版接管 Hook 不争抢，Keychain 状态如实呈现**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-17) 保留。

<a id="mac-app-store-18"></a>

- **18 — 准备与已验收能力一致的 Archive 和审核材料**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#mac-app-store-18) 保留。

<a id="web-workbench-01"></a>

- **WEB-01：跨项目 Web 工作台接入设计**：用户决定暂不做；未实施、未验收。原条目由 Git 和 [第一轮验收表](housekeeping-2026-10-12.md#web-workbench-01) 保留。

## 保留的依据

- Mac 商店候选 [PRD](../planning/backlog/mac-app-store/PRD.md)、[Spec v1](../planning/backlog/mac-app-store/SPEC-store-v1.md)、[Spec v2](../planning/backlog/mac-app-store/SPEC-store-v2.md)、[研究](../planning/backlog/mac-app-store/RESEARCH.md)、[Claude 评审](../planning/backlog/mac-app-store/CLAUDE-REVIEW.md) 和完整 `evidence/` 保留；[索引](../planning/backlog/mac-app-store/CHECKLIST.md) 改为研究与历史设计入口。
- 目录授权、bundle 内 hook、自更新隔离、Codex Desktop 来源边界、两版所有权、Keychain 重输分支等仍作为未来重新评估的依据，不作为当前领取任务。版本限定的沙盒/socket/Keychain 实测见 [triage](../planning/backlog/mac-app-store/evidence/triage/TRIAGE-14-15-17.md)，本次未重复验证或升级为适用于未来版本的保证。
- 原票 18 的同类 App 线索转入既有研究文档，明确是 2026-09-23 历史记录、未本轮复核，不作为本产品审核已获批准的证据。
- Web [PRD](../planning/backlog/web-workbench/PRD.md) 的来源权威、浏览器认证、跨源身份、写入及作者确认边界保留为候选设计。Anamra 接口和真实跨项目闭环仍未核实，不新建执行票或部署。
- SQLite [观察记录](../planning/backlog/agent-integration-2026-09/rollout-sqlite-observation.md) 保留触发前提与历史元数据核对；移出 `issues/`，无 owner、待实施状态或自动调度。只有实际停止 rollout 写入并影响现行观测时再评估需求。

## 流程与验证边界

同步修正所有追踪 Markdown 中指向移除票的链接、backlog 索引与代理接续入口；既有 QA 的“保留 12 票”等措辞标为前一收尾时点的历史记录。完整原票内容仍在 Git，未复制成另一套归档工单。

本次只改项目文档与工单，不改运行代码、已安装应用、发布更新源、标签、用户数据或凭据，不额外发版。验证使用 docs profile、链接/anchor/票数断言，并按项目要求做独立 AGY Gemini exact-head 评审、PR 和合并；最终回执记在 PR。
