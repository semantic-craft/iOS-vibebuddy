# Mac App Store 设计与研究索引

2026-10-12 用户决定暂不实施，09–18 十张施工票已关闭，未实现或验收完成。当前没有可领取的商店票。闭票记录见 [计划收尾](../../../qa/deferred-plan-closeout-2026-10-12.md)。直接分发版继续沿用既有渠道。

## 保留的设计依据

独立沙盒“守望与放行”候选见 [Spec v2](SPEC-store-v2.md)、历史 [Spec v1](SPEC-store-v1.md) 与 [研究](RESEARCH.md)。完整评审和实测留在本目录 `evidence/` 与 `CLAUDE-REVIEW.md`；它们是版本限定的事实及待核实设计，不构成当前开工、签名或发布安排。

原 09–18 的依赖和验收要求由下表、规格、第一轮 QA 以及 Git 保留。历史 HTML 手册和探针的既有存放指针保留，不新建另一套归档票。未来若用户重新提出明确实施目标，先按当时源码、宿主与签名边界重新评估范围，不能直接按旧票状态执行。

以下为历史状态与试验记录；其“待实施”“下一张票”等措辞仅属于各节日期，不是当前任务队列。

## 2026-09-08 现状更正

Grok Build 领取了 09 并在 `~/Projects/iOS-vibebuddy-wt/mac-app-store`（分支 `feat/mac-app-store-watch-approve`）留下未提交改动：商店 target、`tools/vibebuddy-store.entitlements`、`BuildChannel.swift`、`DaemonPort.swift` 及共享代码的可注入化。方向正确，但**实测两处编译失败**，说明该交付从未构建或跑过测试：

- `VibeBuddyMacApp/Sources/BuildChannel.swift` 缺 `import VibeBuddyMacCore`，`xcodebuild -scheme VibeBuddyStore` 报 4 个 `cannot find 'DaemonPort' in scope`，`** BUILD FAILED **`。
- `VibeBuddyMac/Tests/…/DispatchTests.swift` 新增的 `storeAssemblyAdvertisesNoDispatch` 把 `claudeLauncher` 写在 `onDispatch` 之前（`VibeBuddyServer.init` 的实际顺序相反），`swift test` 编译失败。
- `VibeBuddyMac/Package.resolved` 被混入 Sparkle 2.9.6 的 pin（Core 包本身不依赖 Sparkle），需复核清除。

09 的 6 条 AC 无一有证据：未做 Apple Development 重签、未验证 9880 监听与容器 home、未做真机 Pairing。`evidence/grok-build/` 不存在，HANDOFF.md 与 DESIGN-DECISIONS.md 未写。附带确认：`tools/vibebuddy-store.entitlements` 本身有效，重签探针 app 后 `codesign -d --entitlements` 实见 `app-sandbox`。

14 / 15 / 17 的技术未知已实测裁定，记录在 [evidence/triage/TRIAGE-14-15-17.md](evidence/triage/TRIAGE-14-15-17.md)：14 与 17 转 ready-for-agent；15 的答案是否定的（Codex rollout 不持久化审批等待事件），用户 2026-09-08 裁定**砍掉 Desktop 等待提醒、保留任务进度观察**，票 15 已按此重写并转 ready-for-agent，票 18 的审核材料需写明该差异。14 另需票 11 把目录授权扩到 `~/.config/opencode` 等其它 CLI 配置目录。 **2026-09-09 补充**：rollout 无审批记录已独立复证，但该裁定当时未权衡 hooks 通道——实测 `permissionRequest` hook 会为 app-server 线程触发（GLOSSARY 里“Desktop 不执行用户 hooks”对 0.153.4 已过时）。裁定前提有反证，待用户重裁；重裁前票 15 维持现行范围。见 evidence/triage/TRIAGE-14-15-17.md 的 2026-09-09 后续节。

## 历史准备成果（2026-09-08）

- [x] Spec v2 已落到现有 09–18 十张行为切片票；未新建重复编号。09–13、16 为 ready-for-agent；14、15、17、18 为 needs-triage。全部仍未领取，票据整理不构成实施确认。

- [x] [Spec v2](SPEC-store-v2.md)：按 to-spec 综合产品需求、评估建议、测试边界与未决事项；本次调用只授权整理 spec，实施确认仍待完成。

- [x] 当前源码与 Apple 要求的静态调研，见 [RESEARCH.md](RESEARCH.md)。
- [x] 四路线比较与候选 [spec](PRD.md)。
- [x] 存档中的 Claude 提示词 `CLAUDE-CODE-PROMPT.md`；回复见 [CLAUDE-REVIEW.md](CLAUDE-REVIEW.md)（2026-09-07）。
- [x] 旧 8 张候选票已由正式 09–18 取代。
- [x] 对裁决报告的评析与开票 spec，见 [SPEC-store-v1.md](SPEC-store-v1.md)（2026-09-08）：A1–A4 已回写现存 CLAUDE-REVIEW.md 与 RESULTS.md 的相关结论；独立原裁决报告在本目录未找到，未声称修改该原件。W1–W8 映射到 09–18，13 为关卡。
- [~] 沙盒运行实验：探针级已跑（socket / 网络 / exec / 文件），端到端真实 agent 闭环未跑。证据 `evidence/`。
- [x] 路线确定（独立沙盒商店版，2026-09-08）；正式开发按 09–18 推进。
- [x] 逐票实施方案 存档中的 `IMPLEMENTATION-PLAN.html`（2026-09-08，Codex 静态评估已修订，等待用户确认实施；票文件仍是权威）。
- [ ] 真机端到端验收、商店归档与审核准备。

| ID | 工作票 | Blocked by | 当前进度 |
|---|---|---|---|
| MAS-01 | 独立评审与规则复核（历史票已移除） | 无 | **已完成** 2026-09-07 → [CLAUDE-REVIEW.md](CLAUDE-REVIEW.md) |
| MAS-02…08 | 候选票 | — | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-09 | [商店版启动后可与 iPhone Pairing](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-09) | 无 | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-10 | [商店版重启后保留 Pairing 与应用数据](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-10) | 09 | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-11 | [外部目录授权可记住、撤销并恢复](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-11) | 09 | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-12 | [从 Settings 安装 Claude Hook 并收到真实事件](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-12) | 10、11 | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-13 | [关卡：真实 Claude 任务从手机批准、拒绝与回答](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-13) | 12 | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-14 | [Codex CLI 可从手机放行，其它 CLI 可观察](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-14) | 13 | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-15 | [Codex Desktop 任务进度可观察](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-15) | 11、13 | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-16 | [商店界面只提供可执行能力，用量与 Jump 如实反馈](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-16) | 13 | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-17 | [两版接管 Hook 不争抢，Keychain 状态如实呈现](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-17) | 09、12、13、14 | 用户决定暂不做，已关闭；未实施/未验收 |
| MAS-18 | [准备与已验收能力一致的 Archive 和审核材料](../../../qa/deferred-plan-closeout-2026-10-12.md#mac-app-store-18) | 14、15、16、17 | 用户决定暂不做，已关闭；未实施/未验收 |

## 收尾与接续

本表保留历史设计切片与依赖，链接指向闭票记录；不维护下一张可领取票。

本目录随仓库保存（2026-09-23 起）；工单与证据的更新跟代码走同一个 PR。稳定的项目入口在 `docs/agents/mac-app-store.md`。未运行的验收不凭空继承。


## 2026-09-09 Codex Desktop 来源补验（Codex）

用户从 Desktop 界面创建任务 `01a08205-9a29-7220-85d2-db65e42a539e`，以 on-request/workspace-write 触发 harmless printf 的 require_escalated 审批。Desktop 确认 waitingOnApproval；VibeBuddy 收到了普通 hook 与 rollout 信号，但仍 working、没有审批卡。该任务由 Desktop 私有 stdio app-server 持有；独立 socket daemon 虽同为 0.153.4，却报告 notLoaded，resume 返回 active writer 冲突。等待窗口的 rollout 没有审批等待事件。

据此更正前提：Desktop 可以执行普通用户 hooks，但本次升级审批未通过当前集成形成等待卡。既不能写“Desktop 不执行 hooks”，也不能据 daemon 自建线程的成功承诺 Desktop 审批已通。现行票 15 范围不变，MAS 入站与手机闭环仍需独立验收；本段不替代产品重裁。

本轮实现及证据保存在独立 worktree `iOS-vibebuddy-wt/codex-integration-acceptance`：`.scratch/agent-integration-currency/research-20260909.md`、`desktop-source.jsonl`、`audit.jsonl`；正式维护说明为 `docs/codex-integration.md`。用户原生拒绝与手机观察结果将补记在本轮验收记录。


### 2026-09-09 Desktop 验收收尾

此次 Desktop 原生审批随后由用户拒绝，记录窗口内 VibeBuddy 始终没有待审批卡片。用户另报手机当时尚未配对，因此本轮不能裁定手机投递成功或失败。独立 daemon 持有的测试任务已通过真实本轮权限批准和撤卡（15.191 秒）；该证据不覆盖 Desktop 私有实例。维持现行范围和待重裁状态，不据此扩大或否定所有 Desktop 通道。完整证据位于独立 worktree `codex-integration-acceptance/.scratch/agent-integration-currency/acceptance-20260909.md`。

## 2026-09-23 更正：09 的代码已丢失

上文“09 只差真机 Pairing”不再成立。09 的实现一直是 `~/Projects/iOS-vibebuddy-wt/mac-app-store`（分支 `feat/mac-app-store-watch-approve`）里的未提交改动；该目录、分支与相关 stash 均已不存在，Git 不可达对象里也找不到 `BuildChannel` / `DaemonPort`，`main` 没有商店 target。关闭前的下一张票为 09，原代码未合入；`evidence/claude-09/RESULTS-09.md` 里的构建、签名、容器、端口实测只作参考，不能当作已继承的验收。

本目录已随仓库保存在 `docs/planning/backlog/mac-app-store/`。两份 HTML 手册、提示词和探针源码只在 `~/Projects/_shared-work/archive/iOS-vibebuddy-scratch-2026-09-23.tgz`。
