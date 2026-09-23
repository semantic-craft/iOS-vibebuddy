# Mac App Store 下一步清单

更新：2026-09-08（Grok 领取 09 后交付未编译通过的半成品；14/15/17 的技术未知已由 Claude 实测裁定）。用户明确列为下一步重要工作；完整直接分发版继续。此文件是本工作线的状态入口，ticket 保存执行证据，不在多个看板重复维护完成状态。

## 下一次从哪里开始

专用入口：[Grok Build HTML 实施手册](GROK-BUILD-PLAN.html)。含全部硬依赖、建议顺序、逐票步骤、技术裁定和 Codex E2E 矩阵。提示词：[Grok 实施](GROK-BUILD-PROMPT.md) / [Codex 独立验收](CODEX-E2E-PROMPT.md)。Grok 的自验交付与 Codex 的独立接受分别记录。

先核对实际 HEAD、未提交改动及 owner。路线已定为独立沙盒商店版（守望与放行），综合 spec 见 [SPEC-store-v2.md](SPEC-store-v2.md)（needs-triage，含未决事项）；历史开票依据保留 [SPEC-store-v1.md](SPEC-store-v1.md)，工作票为 09–18；02–08 已作废。下一张可执行票：**09** 收尾（只剩真机 Pairing，需要 Hermes 解锁在手边），随后 10 与 11 可并行。09 完成后 10 与 11 可并行；13 是关卡，通过前不投入 14 及之后。

本轮第一阶段已完成（[评估记录](evidence/PLAN-REVIEW.md)）：逐票静态核对并修订 IMPLEMENTATION-PLAN.html 与 09–18 的 Comments；全部票仍 not-started / unassigned。用户现指定由 Grok Build 实施、Codex 后续独立设计复核与 E2E。将 [Grok 主提示词](GROK-BUILD-PROMPT.md) 交给 Grok 后从 09 领取；本任务尚未启动任何执行会话。历史票据中的“本轮仅整理”是开票阶段记录，不覆盖用户后续交付实施提示词的授权。

下次先核对 HEAD、工作区与 owner；第一阶段 HEAD=053a87b；本次复核另见语音/音频及相关 ADR 的并行 WIP，均未改动，实施前重新核对当前基线。09 先完成独立 target 与最小运行隔离。13 未通过，14–18 一律不领票；17 另依赖 14 的安装器接管。待解问题：14 的 OpenCode bundle 引用/双向命令识别，15 的真实 Desktop rollout 等待信号，17 的 Keychain 共享与直接版签名不变边界。不得靠删功能、伪造等待或改直接版来绕过。

本轮没有跑探针、构建或真机验收；报告原先的“逐段闭环已通过”已纠正为入站 HTTP 前提成立，真实 agent 闭环仍由 13 验证。

## 2026-09-08 现状更正

Grok Build 领取了 09 并在 `~/Projects/iOS-vibebuddy-wt/mac-app-store`（分支 `feat/mac-app-store-watch-approve`）留下未提交改动：商店 target、`tools/vibebuddy-store.entitlements`、`BuildChannel.swift`、`DaemonPort.swift` 及共享代码的可注入化。方向正确，但**实测两处编译失败**，说明该交付从未构建或跑过测试：

- `VibeBuddyMacApp/Sources/BuildChannel.swift` 缺 `import VibeBuddyMacCore`，`xcodebuild -scheme VibeBuddyStore` 报 4 个 `cannot find 'DaemonPort' in scope`，`** BUILD FAILED **`。
- `VibeBuddyMac/Tests/…/DispatchTests.swift` 新增的 `storeAssemblyAdvertisesNoDispatch` 把 `claudeLauncher` 写在 `onDispatch` 之前（`VibeBuddyServer.init` 的实际顺序相反），`swift test` 编译失败。
- `VibeBuddyMac/Package.resolved` 被混入 Sparkle 2.9.6 的 pin（Core 包本身不依赖 Sparkle），需复核清除。

09 的 6 条 AC 无一有证据：未做 Apple Development 重签、未验证 9880 监听与容器 home、未做真机 Pairing。`evidence/grok-build/` 不存在，HANDOFF.md 与 DESIGN-DECISIONS.md 未写。附带确认：`tools/vibebuddy-store.entitlements` 本身有效，重签探针 app 后 `codesign -d --entitlements` 实见 `app-sandbox`。

14 / 15 / 17 的技术未知已实测裁定，记录在 [evidence/triage/TRIAGE-14-15-17.md](evidence/triage/TRIAGE-14-15-17.md)：14 与 17 转 ready-for-agent；15 的答案是否定的（Codex rollout 不持久化审批等待事件），用户 2026-09-08 裁定**砍掉 Desktop 等待提醒、保留任务进度观察**，票 15 已按此重写并转 ready-for-agent，票 18 的审核材料需写明该差异。14 另需票 11 把目录授权扩到 `~/.config/opencode` 等其它 CLI 配置目录。 **2026-09-09 补充**：rollout 无审批记录已独立复证，但该裁定当时未权衡 hooks 通道——实测 `permissionRequest` hook 会为 app-server 线程触发（CONTEXT 里“Desktop 不执行用户 hooks”对 0.153.4 已过时）。裁定前提有反证，待用户重裁；重裁前票 15 维持现行范围。见 evidence/triage/TRIAGE-14-15-17.md 的 2026-09-09 后续节。

## 准备成果

- [x] Spec v2 已落到现有 09–18 十张行为切片票；未新建重复编号。09–13、16 为 ready-for-agent；14、15、17、18 为 needs-triage。全部仍未领取，票据整理不构成实施确认。

- [x] [Spec v2](SPEC-store-v2.md)：按 to-spec 综合产品需求、评估建议、测试边界与未决事项；本次调用只授权整理 spec，实施确认仍待完成。

- [x] 当前源码与 Apple 要求的静态调研，见 [RESEARCH.md](RESEARCH.md)。
- [x] 四路线比较与候选 [spec](PRD.md)。
- [x] [Claude 提示词](CLAUDE-CODE-PROMPT.md)；回复见 [CLAUDE-REVIEW.md](CLAUDE-REVIEW.md)（2026-09-07）。
- [x] 旧 8 张候选票已由正式 09–18 取代。
- [x] 对裁决报告的评析与开票 spec，见 [SPEC-store-v1.md](SPEC-store-v1.md)（2026-09-08）：A1–A4 已回写现存 CLAUDE-REVIEW.md 与 RESULTS.md 的相关结论；独立原裁决报告在本目录未找到，未声称修改该原件。W1–W8 映射到 09–18，13 为关卡。
- [~] 沙盒运行实验：探针级已跑（socket / 网络 / exec / 文件），端到端真实 agent 闭环未跑。证据 `evidence/`。
- [x] 路线确定（独立沙盒商店版，2026-09-08）；正式开发按 09–18 推进。
- [x] 逐票实施方案 [IMPLEMENTATION-PLAN.html](IMPLEMENTATION-PLAN.html)（2026-09-08，Codex 静态评估已修订，等待用户确认实施；票文件仍是权威）。
- [ ] 真机端到端验收、商店归档与审核准备。

| ID | 工作票 | Blocked by | 当前进度 |
|---|---|---|---|
| MAS-01 | [独立评审与规则复核](issues/01-independent-review.md) | 无 | **已完成** 2026-09-07 → [CLAUDE-REVIEW.md](CLAUDE-REVIEW.md) |
| MAS-02…08 | 候选票 | — | **作废** 2026-09-08，由 09–18 取代 |
| MAS-09 | [商店版启动后可与 iPhone Pairing](issues/09-store-target-pairs.md) | 无 | **进行中（Claude）**：构建/签名/容器/端口/隔离全部 PASS，只差真机 Pairing → [证据](evidence/claude-09/RESULTS-09.md) |
| MAS-10 | [商店版重启后保留 Pairing 与应用数据](issues/10-container-storage.md) | 09 | 未开始，ready-for-agent |
| MAS-11 | [外部目录授权可记住、撤销并恢复](issues/11-authorized-locations.md) | 09 | 未开始，ready-for-agent |
| MAS-12 | [从 Settings 安装 Claude Hook 并收到真实事件](issues/12-native-installer-claude.md) | 10、11 | 未开始，ready-for-agent |
| MAS-13 | [关卡：真实 Claude 任务从手机批准、拒绝与回答](issues/13-approval-gate.md) | 12 | 未开始，ready-for-agent |
| MAS-14 | [Codex CLI 可从手机放行，其它 CLI 可观察](issues/14-native-installer-other-clis.md) | 13 | 未开始，**ready-for-agent**（triage 已裁定）|
| MAS-15 | [Codex Desktop 任务进度可观察](issues/15-codex-desktop-remind-only.md) | 11、13 | 未开始，**ready-for-agent**（2026-09-08 用户裁定砍掉等待提醒；2026-09-09 新证据待重裁，见上）|
| MAS-16 | [商店界面只提供可执行能力，用量与 Jump 如实反馈](issues/16-capability-switches.md) | 13 | 未开始，ready-for-agent |
| MAS-17 | [两版接管 Hook 不争抢，Keychain 状态如实呈现](issues/17-coexistence-keychain.md) | 09、12、13、14 | 未开始，**ready-for-agent**（triage 已裁定，走重输分支）|
| MAS-18 | [准备与已验收能力一致的 Archive 和审核材料](issues/18-submission-readiness.md) | 14、15、16、17 | 未开始，needs-triage |

## 收尾与接续

每次推进后只在这里更新下一张可执行票，在相应 ticket 写 Owner、Progress、证据和剩余疑点。未运行的检查保持未完成。不要在 agent 规则里复制实时进度。

本目录受 Git 忽略，不能声称已经跨机保存。稳定的项目入口在 `docs/agents/mac-app-store.md`；换机先找实际工作材料，缺失时按该文件恢复计划，不凭空继承验收。需要跨机移交时，按用户授权和项目同步规则另外交付 `.scratch/mac-app-store/`；不要强行 git add -f。


## 2026-09-09 Codex Desktop 来源补验（Codex）

用户从 Desktop 界面创建任务 `01a08205-9a29-7220-85d2-db65e42a539e`，以 on-request/workspace-write 触发 harmless printf 的 require_escalated 审批。Desktop 确认 waitingOnApproval；VibeBuddy 收到了普通 hook 与 rollout 信号，但仍 working、没有审批卡。该任务由 Desktop 私有 stdio app-server 持有；独立 socket daemon 虽同为 0.153.4，却报告 notLoaded，resume 返回 active writer 冲突。等待窗口的 rollout 没有审批等待事件。

据此更正前提：Desktop 可以执行普通用户 hooks，但本次升级审批未通过当前集成形成等待卡。既不能写“Desktop 不执行 hooks”，也不能据 daemon 自建线程的成功承诺 Desktop 审批已通。现行票 15 范围不变，MAS 入站与手机闭环仍需独立验收；本段不替代产品重裁。

本轮实现及证据保存在独立 worktree `iOS-vibebuddy-wt/codex-integration-acceptance`：`.scratch/agent-integration-currency/research-20260909.md`、`desktop-source.jsonl`、`audit.jsonl`；正式维护说明为 `docs/codex-integration.md`。用户原生拒绝与手机观察结果将补记在本轮验收记录。


### 2026-09-09 Desktop 验收收尾

此次 Desktop 原生审批随后由用户拒绝，记录窗口内 VibeBuddy 始终没有待审批卡片。用户另报手机当时尚未配对，因此本轮不能裁定手机投递成功或失败。独立 daemon 持有的测试任务已通过真实本轮权限批准和撤卡（15.191 秒）；该证据不覆盖 Desktop 私有实例。维持现行范围和待重裁状态，不据此扩大或否定所有 Desktop 通道。完整证据位于独立 worktree `codex-integration-acceptance/.scratch/agent-integration-currency/acceptance-20260909.md`。

## 2026-09-23 更正：09 的代码已丢失

上文“09 只差真机 Pairing”不再成立。09 的实现一直是 `~/Projects/iOS-vibebuddy-wt/mac-app-store`（分支 `feat/mac-app-store-watch-approve`）里的未提交改动；该目录、分支与相关 stash 均已不存在，Git 不可达对象里也找不到 `BuildChannel` / `DaemonPort`，`main` 没有商店 target。下一张票仍是 09，从零实现；`evidence/claude-09/RESULTS-09.md` 里的构建、签名、容器、端口实测只作参考，不能当作已继承的验收。

本目录已随仓库保存在 `docs/planning/backlog/mac-app-store/`。两份 HTML 手册、提示词和探针源码只在 `~/Projects/_shared-work/archive/iOS-vibebuddy-scratch-2026-09-23.tgz`。
