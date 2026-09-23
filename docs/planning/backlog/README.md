# 未完成施工清单（2026-09-23 盘点）

这里是当前**全部未完成**计划的入口。2026-09-23 的项目清理核对了 `.scratch` 归档包、`docs/planning/roadmap-2026-09.json`、全部 PR 和代码，只把核实后仍未完成的条目收录进来。已完成或已被取代的条目不再列出，证据见本文末尾。

`.scratch/` 被 Git 忽略，worktree 和其他机器都看不到。仍在进行的工单因此放在这里，随仓库保存。原票保持原文，本文件只给状态和建议。领取一张票时先核对当前源码。

## 开发项

| ID | 内容 | 票据 | 状态 | 依据 | 建议 |
|---|---|---|---|---|---|
| AI-04 | Claude `Stop` 带 `background_tasks` / `session_crons` 时不算完成 | [04](agent-integration-2026-09/issues/04-claude-stop-background-tasks.md) | ready-for-agent | `HookParser` 不读这两个字段，`/loop` 会话会误报完成 | **优先**，直接影响提醒准确性 |
| C-1 | Swift 安装器（Claude / Codex / Grok / Cursor） | roadmap JSON `C-1` | ready | `HookSetup.swift` 仍调用 `python3` | **优先**，陌生 Mac 没有 python3；与 AI-08 一起定 |
| AI-08 | 分发形态：Claude/Cursor 插件 vs Swift 安装器 | [08](agent-integration-2026-09/issues/08-distribution-plugin-vs-installer.md) | ready-for-human | 需要产品决策 | 与 C-1 同时拍板 |
| AI-05 | Claude 后台会话改读 `claude agents --json` | [05](agent-integration-2026-09/issues/05-claude-agents-json.md) | ready-for-agent | `ClaudeBackgroundSessions` 仍读 `~/.claude/jobs/*/state.json`，官方声明它不是稳定接口 | 保留 |
| AI-06 | 观测健康诊断补 Cursor 行 | [06](agent-integration-2026-09/issues/06-cursor-observation-health-row.md) | ready-for-agent | `ObservationHealthDetector` 只有 Claude / Codex / Grok | 保留，小票 |
| AI-02 | Grok leader 扇出实测、托管会话恢复、`grok -r` 续接 | [02](agent-integration-2026-09/issues/02-grok-leader-fanout-and-recovery.md) | ready-for-agent | 代码里只有 `--no-leader`，没有恢复逻辑 | 保留 |
| AI-03 | Grok status line 转发和活跃会话名册 | [03](agent-integration-2026-09/issues/03-grok-statusline-and-registry.md) | ready-for-agent | 代码里没有对应实现 | 保留 |
| WR-07 | 通知携带 question id，手表横幅回答不再靠推断 | [07](watch-wrist-resolve/issues/07-banner-reply-question-id.md) | needs-triage | Mac 与 iPhone 的推送已带 `questionId`（#248），但手表仍绑定第一份中继状态；ADR-0033 仍把它列为剩余缺口 | 保留，只剩手表侧 |
| D-1 / D-2 | 供应商连接上限到顶时结束通话、一键重拨；语音文档与 ADR-0001 同步 | [02](realtime-verify/issues/02-provider-limit-redial.md) + roadmap JSON | ready-for-agent | 没有重拨代码 | 保留 |
| E-1 | Icon Composer 分层图标 | roadmap JSON `E-1` | 可开工 | 仓库只有 `AppIcon.appiconset` PNG；Xcode 27 已在用，原先的阻塞已解除 | 保留 |
| G-4 | 无障碍检查（VoiceOver / 动态字体 / Reduce Motion） | roadmap JSON `G-4` | 部分完成 | Xcode 27 构建和 zh-Hans 已完成，无障碍检查没做 | 缩成只做无障碍 |
| C-3 / C-5 | 首次运行流程；一等 / 社区级标注 | roadmap JSON | 部分完成 | #224 加了引导清单；README 已标出部分社区适配 | 缩小范围后保留 |
| MAS-09…18 | Mac App Store 沙盒版 | [CHECKLIST](mac-app-store/CHECKLIST.md) | **代码已丢失，需从 09 重做** | 见下节 | 保留方向，从 09 重做 |

## 需要你拍板

| ID | 问题 | 来源 |
|---|---|---|
| AI-08 | Hook 分发用官方插件还是 Swift 安装器 | [08](agent-integration-2026-09/issues/08-distribution-plugin-vs-installer.md) |
| A-12 / DEC-APNS | 公开版在 App 关闭后如何送达推送 | ADR-0013（仍是 Proposed）、roadmap JSON `A-12` |
| M-07 / M-09 / M-10 | 手表阅读任务上下文、补充指令、发起新任务：是否还做 | ADR-0021 已把手表收窄为提醒入口；原工单目录已不存在，只剩 roadmap JSON 的 spec |
| MAS-15 | Codex Desktop 等待提醒是否保留：2026-09-08 已裁定砍掉，但 09-09 的新证据推翻了裁定前提 | [TRIAGE-14-15-17](mac-app-store/evidence/triage/TRIAGE-14-15-17.md) |
| G-5 | 设计检查表和截图矩阵：做，还是由已有的 App Store 截图覆盖后关闭 | roadmap JSON `G-5` |

## 只能由你在真机上做的验收

- **H-2**：冻结候选版本后，连续实际使用半小时，不能有新增漏接。不能用提交审核代替。
- **ADR-0033**：批准已在 2026-09-23 03:08 通过；拒绝和回答还没单独验证。
- **手表腕上功能**（喊停、快捷回答、触觉、Double Tap）：[06](watch-wrist-resolve/issues/06-device-acceptance.md)。
- **roadmap 中的 A-03、B-U、M-01、M-11、D-U、E-2、H-1、H-5**：已被历次发布门部分覆盖。下次整理 roadmap 时，把发布门已覆盖的条目标为完成，其余保留。

## 观察项（暂不动手）

- **AI-07**：Codex 从 rollout 文件迁到 SQLite 后的降级预案。0.153.4 仍在写 rollout。见 [07](agent-integration-2026-09/issues/07-codex-rollout-degradation.md)。
- **Antigravity hooks**：上游有 bug，已记录在 `docs/multi-cli-hook-setup.md`。

## Mac App Store：代码已丢失

`CHECKLIST.md` 记的是“09 只差真机 Pairing”，这已经不成立。09 的实现是未提交改动，放在 `~/Projects/iOS-vibebuddy-wt/mac-app-store`（分支 `feat/mac-app-store-watch-approve`）。那个目录、那个分支和相关 stash 都已不存在。在 Git 不可达对象里也没找到 `BuildChannel` / `DaemonPort`，`main` 上没有商店 target。

还留着的是产品与技术结论，重做时直接沿用：

- 沙盒里连接 Codex socket 会报 EPERM（死路）。
- hooks 入站审批可行，但 hook 必须走 bundle 内路径，不能带 env 前缀。
- 沙盒里生成子进程运行 CLI 全部失败。
- 商店版不能继承直接版的 Keychain 条目，而且读取可能挂死。

这些结论的出处是 [RESULTS.md](mac-app-store/evidence/RESULTS.md)、[TRIAGE-14-15-17.md](mac-app-store/evidence/triage/TRIAGE-14-15-17.md) 和 [CLAUDE-REVIEW.md](mac-app-store/CLAUDE-REVIEW.md)。`CHECKLIST.md` 链接的两份 HTML 实施手册和探针源码没有复制进仓库，仍在归档包里。

## 已核实完成、不再列出

通知分类 01–14、观测健康 01–03、手表配额和表盘复杂功能、远程访问 01–03、跨端审计 01–05、手表腕上功能 01/02/03/05（1.3.8）、语音设置重构（#139–#142）、iPhone 第 6–8 轮设计（已由 ADR-0014 取代）、Grok ACP 托管（#233）、Mac App Store 旧票 02–08（已作废）、全部 6 月批次。PR #37、#42、#45、#228、#248 都已合并。未合并就关闭的 #50、#69、#143、#160、#171–#182，其工作都已通过其他 PR 落地。

## 归档位置

- `~/Projects/_shared-work/archive/iOS-vibebuddy-scratch-2026-09-23.tgz`：完整的 `.scratch`，含已完成工单、HTML 计划、探针和证据。
- `~/Projects/_shared-work/archive/iOS-vibebuddy-hidden-refs-2026-09-23.bundle`：Metis 退役备份引用和 Codex 快照引用。
- `~/Projects/_shared-work/archive/iOS-vibebuddy-wip-cueaudience-2026-09-23.bundle`：本地 WIP 标签。
