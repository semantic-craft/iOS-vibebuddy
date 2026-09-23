# 15 — Codex Desktop 任务进度可观察

Status: ready-for-agent
Progress: not-started
Priority: next-cycle-important
Owner: unassigned
Blocked by: 11 外部目录授权可记住、撤销并恢复；13 关卡：真实 Claude 任务从手机批准、拒绝与回答
Spec: Spec v2（本工作线综合稿）+ 2026-09-08 用户范围裁定

## What to build

用户授权 Codex 配置目录后，商店版通过 Codex rollout stream 观察真实 Desktop Session 的开始、进行与结束，并在 Mac、iPhone 与通知里如实呈现进度。**不提供审批或回答入口，也不提示「正在等待批准」**——2026-09-08 实测确认 Codex 不把审批等待写入 rollout，沙盒又连不上 app-server 实时通道，用户已裁定砍掉等待提醒。Jump 只激活宿主应用，不定位线程。

> **2026-09-09 — 排除等待提醒的前提正在复审，不要当成已定论。** rollout 无审批记录已独立复证（起 `approvalPolicy: "untrusted"` 的线程跑命令，审批确实发生，rollout 里三种 marker 一个都没有）。但当时判定“没有可用信号”只权衡了 rollout 与 app-server socket 两条通道，漏了 hooks：实测 daemon 会为经 `thread/start` 创建的线程触发 `~/.codex/hooks.json` 里 `source: "user"` 的 hook，**包括同步的 `permissionRequest` 网关**，且它先于审批扇出完成。CONTEXT.md 的 “Codex Desktop does not execute user CLI hooks” 对 0.153.4 已过时。
>
> 现行范围（只做进度观察）在用户重裁前不变，本票可以照常实施。但**不要在代码注释、UI 文案或票 18 的审核材料里写“Codex Desktop 的等待无法被观察”**——那句话现在没有证据支持。补验很便宜：在 Codex Desktop 里跑一条需要审批的命令，看 vibebuddy 是否收到 `permissionRequest`。
>
> 证据：`evidence/triage/TRIAGE-14-15-17.md` 的 2026-09-09 后续节；复现步骤在 `.scratch/agent-integration-currency/research-20260908.md`。

## Acceptance criteria

- [ ] 真实隔离 Desktop Session 的 rollout 信号绑定到正确 Session，`task_started` / `task_complete` / `turn_aborted` / `item_completed` 驱动三态更新；未观察到的状态不猜测、不补齐。
- [ ] Desktop Session 在手机与 Mac 上均为只读：无 approve / answer / Steer / continue 入口，通知动作、语音与服务端行为一致；禁用不得破坏 13 已通过的 Claude 审批与问答。
- [ ] 商店不启动 app-server、socket 或 CLI fallback，Settings 不显示相应开关；直接版仍保持 ADR-0011 主源行为与 Desktop 审批能力。
- [ ] 撤销目录授权停止观察并显示恢复入口，重新授权可恢复；未知的进程身份不能误报 Abandoned、无任务或 healthy。
- [ ] Codex 来源诊断只呈现适用的 Hook、rollout、Status line 信号，并明确告知商店版不观察 Desktop 审批等待；Jump 返回已有 activatedApp 语义并实际激活宿主。
- [ ] 不实现等待提醒，也不用超时、静默或进程探针推断等待。若 Codex 将来开始持久化审批事件，另开新票，不在本票内偷加。

## Readiness and verification

技术缺口已于 2026-09-08 实测定因（见 [evidence/triage/TRIAGE-14-15-17.md](../evidence/triage/TRIAGE-14-15-17.md)），用户已裁定范围：保留进度观察、去掉等待提醒。本票据此转 ready-for-agent。票 18 的审核材料必须如实说明商店版对 Codex Desktop 只有进度观察、没有审批。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：决定 c 已采纳并改票正文为运行时隔离。新增关键缺口：CodexRolloutMonitor decoder 接受审批事件，但 hooks/README 与 ADR-0011 不保证 Desktop 持久化审批；先实测后判断，不把“支持解码”当“已能观察”。还须隔离进程身份/退休探针，防止误报 Abandoned。 详见修订后的 IMPLEMENTATION-PLAN.html 票 15；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 needs-triage；不代表已确认实施。

- 2026-09-08 Claude triage（未领取实施，**范围问题上交用户**）：实质缺口已定因，答案是否定的。详见 [evidence/triage/TRIAGE-14-15-17.md](../evidence/triage/TRIAGE-14-15-17.md)。
  Codex 的 rollout 流不持久化审批等待事件。`~/.codex/sessions` 642 个真实 rollout（其中 618 个含 `task_complete`，`originator` 出现 2786 次 `"Codex Desktop"`）中，`exec_approval_request`、`apply_patch_approval_request`、`request_user_input`、`elicitation_request` 命中数均为 **0**。抽样 40 个 rollout 的 `event_msg.payload.type` 全量分布只有 agent_reasoning / token_count / agent_message / task_started / user_message / patch_apply_end / task_complete / thread_settings_applied / sub_agent_activity / web_search_end / mcp_tool_call_end / image_generation_end / context_compacted / turn_aborted；`world_state` 是会话配置快照，不含等待状态。
  架构上也解释得通：审批走 app-server 的 JSON-RPC serverRequest 实时通道（`CodexAppServerReducer.serverRequestMethod` 只认带 `id` 的请求），rollout 是线程条目历史，不记录瞬时请求。`CodexRolloutMonitor` 里的 `exec_approval_request` 分支对 rollout 路径是死代码。隔离 `CODEX_HOME` + `-s read-only` + `approval_policy=on-request` 跑被沙盒拒绝的命令，rollout 也只有 `custom_tool_call` / `custom_tool_call_output`。
  沙盒商店版又连不上 app-server socket（probe2 已证 EPERM）。因此本票要求的等待提醒在当前边界内**没有可用信号**，不能靠静默或超时猜测补足（票已明确禁止）。
  按票中「无法取得信号时提交定因与具体选项，保持产品要求未完成，不自动降低范围」，状态保持 needs-triage，等用户裁定：
  1. 保留 Desktop 观察、去掉等待提醒——rollout 可靠提供 task_started / task_complete / turn_aborted / item_completed，商店版能显示 Desktop 任务进度与完成，只是不提示「正在等你批准」。
  2. 整体推迟 15，先交付 09–14、16–18。
  3. 另找信号——需要 Apple Events 或读 Desktop 私有状态，被沙盒与审核规则挡住，不推荐。
  无论选哪个，票 18 的审核材料都要如实说明 Desktop 只有进度观察、没有审批。

- 2026-09-08 用户裁定（范围变更）：选择方案 1——**砍掉 Desktop 等待提醒，保留任务进度观察**。票标题、What to build 与 AC 已按此重写，Status 转 ready-for-agent。原「等待提醒」需求不再属于商店版范围；`CodexRolloutMonitor` 中针对 rollout 路径的审批事件分支属于死代码，实施时如实处理，不据此声称支持。票 18 需在审核材料写明该差异。


## 2026-09-09 Codex Desktop 来源补验（Codex）

用户从 Desktop 界面创建任务 `01a08205-9a29-7220-85d2-db65e42a539e`，以 on-request/workspace-write 触发 harmless printf 的 require_escalated 审批。Desktop 确认 waitingOnApproval；VibeBuddy 收到了普通 hook 与 rollout 信号，但仍 working、没有审批卡。该任务由 Desktop 私有 stdio app-server 持有；独立 socket daemon 虽同为 0.153.4，却报告 notLoaded，resume 返回 active writer 冲突。等待窗口的 rollout 没有审批等待事件。

据此更正前提：Desktop 可以执行普通用户 hooks，但本次升级审批未通过当前集成形成等待卡。既不能写“Desktop 不执行 hooks”，也不能据 daemon 自建线程的成功承诺 Desktop 审批已通。现行票 15 范围不变，MAS 入站与手机闭环仍需独立验收；本段不替代产品重裁。

本轮实现及证据保存在独立 worktree `iOS-vibebuddy-wt/codex-integration-acceptance`：`.scratch/agent-integration-currency/research-20260909.md`、`desktop-source.jsonl`、`audit.jsonl`；正式维护说明为 `docs/codex-integration.md`。用户原生拒绝与手机观察结果将补记在本轮验收记录。


### 2026-09-09 Desktop 验收收尾

此次 Desktop 原生审批随后由用户拒绝，记录窗口内 VibeBuddy 始终没有待审批卡片。用户另报手机当时尚未配对，因此本轮不能裁定手机投递成功或失败。独立 daemon 持有的测试任务已通过真实本轮权限批准和撤卡（15.191 秒）；该证据不覆盖 Desktop 私有实例。维持现行范围和待重裁状态，不据此扩大或否定所有 Desktop 通道。完整证据位于独立 worktree `codex-integration-acceptance/.scratch/agent-integration-currency/acceptance-20260909.md`。

- 2026-09-23 重裁（对照同类项目后拍板）：**维持 2026-09-08 的范围**——商店版只观察 Codex Desktop 进度，不承诺等待提醒。依据：Octane0411/open-vibe-island#506（open）与我们 09-09 实测一致，Desktop 线程在自建 app-server 上是 `notLoaded`，回答回不到 Desktop；openai/codex#28833（open）`PermissionRequest` 在自动审批分流之前触发、会误报；clawd-on-desk#1040（Desktop 26.915）细粒度 `request_permissions` 不触发该 hook；官方给 Desktop 审批的出路是 ChatGPT 手机端 Codex Remote。若 hook 真的触发，照 CLI 走同一张卡，但审核材料不承诺；每个 Codex Desktop 新版本复测一次并跟踪 #28833。
