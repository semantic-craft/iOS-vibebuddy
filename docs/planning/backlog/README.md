# 施工清单（2026-09-23 更新）

这里是当前全部计划的入口：上半部分是今天已完成的改动，下半部分是**全部未完成**的施工项。可交互版本（带可复制的 agent 提示词）：https://claude.ai/artifact/M4n5cM4CeHYbv7sTGtH6VF 。

**2026-09-23 优先级**：先完善本机 GitHub 公开版的性能和已知问题；Mac App Store 版延后。2026-09-23 的项目清理核对了 `.scratch` 归档包、`docs/planning/roadmap-2026-09.json`、全部 PR 和代码；未完成部分只收核实后的条目，更早已完成或已被取代的条目见本文末尾。

`.scratch/` 被 Git 忽略，worktree 和其他机器都看不到。仍在进行的工单因此放在这里，随仓库保存。原票保持原文，本文件只给状态和建议。领取一张票时先核对当前源码。

## 2026-09-23 已完成

#264–#273 经独立 Opus 子代理评审（`docs/agents/pr-review.md`；#263 为 Grok 评审，#262 未单独评审），合并后从 `main` 重建并替换 `/Applications`（开发版，Developer ID 签名、未公证，版本号仍是 1.3.32；下次正式发布 Mac 1.3.33 带上这些改动）。

| PR | 改动 | 效果 |
|---|---|---|
| #262 | 删除三个无人引用的手动 QA 脚本 | 清理 |
| #263 | 删除无人引用的代码与已废弃的手表「全部已读」链路（净删约 600 行）；未完成工单从 `.scratch` 搬进本目录；归档隐藏 ref 与 WIP 标签 | 工单随仓库保存，worktree 可见 |
| #264 | **AI-04**：Claude `Stop` 带后台任务时不误报完成；`/loop` 轮次安静落定；后台 shell 标注"还有 N 项后台任务"；迟到的工具回执不再重开已完成的轮次 | 提醒更准 |
| #265 | **PERF-01 主因**：按你的决定删除 History 存档（29.6 GB 三元组全文索引，活跃会话约每 15 s 整体重建）；保留实时会话阅读（只读 `SessionTranscriptReader`）；快照里交接扫描加缓存；工具账本写入 2 s → 10 s，`facts` 读取前主动写盘；新版首次启动自动删除旧索引 | CPU 均值 11.2% → 2.7%，峰值 98.9% → 14.8%（合并后从 main 重装复测；PR 评论里的首测为 3.1% / 18.4%） |
| #266 | **C-1**：Swift 安装器替换全部 python 安装脚本（Claude、Codex、Grok、Cursor、OpenCode、Antigravity）；脚本复制到固定目录 `~/Library/Application Support/vibebuddy/bin/`；`vibebuddyd hooks install|uninstall|status` | 陌生 Mac 不再需要 python3；Codex 信任不再随 App 更新失效 |
| #267 | **AI-05**：Claude 后台会话改读官方 `claude agents --json`；`~/.claude/jobs` 有变化或距上次满 60 s 才调用，同一时刻只跑一次、从不阻塞界面与审批提醒；CLI 不可用时回退旧文件 | 不再依赖官方声明不稳定的内部文件 |
| #270 | 施工清单记录 #262–#267（文档） | — |
| #268 | 全量 `swift test` 的时序偶发失败改为等显式信号（生产行为不变） | 测试稳定 |
| #269 | 生产代码里的 `waitUntilExit()`（`TerminalInjector`、`WorkspaceChangesReader`）移出 Swift 并发线程池 | 卡住的子进程不再拖住 App 的并发线程 |
| #271 | `claude agents` 与 Grok ACP 退出等待加时限（TERM → 1 s → KILL） | 卡死的 CLI 最多占用约 timeout + 3 s |
| #272 | `claude agents` 的 stdout 读取受同一时限约束，返回前关闭读端 | 不再遗留阻塞的读线程与 fd |
| #273 | 命令监管器（`POSIXCommandSupervisor`）生成子进程时只继承 stdin/stdout/stderr | 子进程不再意外持有别的管道 |
| 本轮收尾 PR | Codex 用量子进程（`CodexAppServerUsageProvider`）同样只继承三个 fd；补回归测试 | 修掉 #272 新测试在全量并发下的偶发失败（Codex 子进程持有了它的管道读端） |

本机环境变化：Claude 与 Grok 的 hook 已迁到固定目录（迁移前的配置备份在 `~/Projects/_shared-work/iOS-vibebuddy/hook-migration-2026-09-23/`）；Codex 仍用旧路径，等你重新信任。旧 History 索引已删，空间被 13:11 的 Time Machine 本地快照暂时占用，macOS 会自动回收。

仓库状态（2026-09-23 收尾，#274 合并后）：没有开放 PR；远端只剩 `main` 与 `gh-pages`；只剩一个 worktree（本会话）。相关会话已归档。已删除测试残留：`$TMPDIR` 下约 6500 个 `vb-*` / `recap-*` 等测试临时目录、约 40 个 QA / E2E 用的 `com.vibebuddy.*` 偏好域（保留正式的 `com.vibebuddy.mac`）。

## 开发项

| ID | 内容 | 票据 | 状态 | 依据 | 建议 |
|---|---|---|---|---|---|
| PERF-01 | Mac App 性能收尾 | [01](performance/issues/01-mac-cpu-and-memory.md) | ready-for-agent（主因已修，#265） | 稳定后 CPU 均值 2.7%；待补：三档负载 × 10 min、2 h 内存曲线；启动后第一分钟约 50% CPU（加载几 MB 账本） | **优先** |
| A-12 前置 | CloudKit 私有库提醒推送原型 | [01](public-push/issues/01-cloudkit-alert-push-prototype.md) | ready-for-agent | ADR-0013 已选方向 D，需实测延迟与按钮 | 保留，通过后 A-12 按 D 实现 |
| C-1b | 评审留下的小尾巴 | — | ready-for-agent | ① ~~`ObservationHealthDetector` 尊重 `CLAUDE_CONFIG_DIR` / `CODEX_HOME`~~（诊断这一半已在 #278 完成），后台会话的 jobs 目录尊重 `CLAUDE_CONFIG_DIR`；② `configKey` 解析软链（C-1 W2）；③ 旧 manifest 裸 key 迁移（C-1 N1）；④ 检测标记不写死 9876（C-1 N2）；⑤ 从 checkout 运行 `vibebuddyd hooks install` 且装着旧版 App 时会复制旧脚本（C-1 W1，目前靠先装新 App 或 `--hooks-dir` 规避）；⑥ 跳转查找加约 3 s 总时限、`/jump` 新分支补测试（AI-05）；⑦ `/ledger/flush` 路由测试、`VIBEBUDDY_PORT` 非法值处理、`LedgerFlushRequest` 复用 NoRedirects / 无 cookie 配置（PERF-01） | 一张小票做完 |
| T-1 | 测试不清理临时目录 | — | ready-for-agent | 约 10 个测试文件（`DeviceRegistryTests`、`EnvironmentDetectorTests`、`TokenConsumptionScanTests`、`ApprovalRoutesTests`、`DevicePushFailureTests`、`ClaudeBackgroundLauncherTests`、`AttentionTests`、`BackgroundAttachTests`、`CodexAppServerApprovalTests` 等）在 `$TMPDIR` 建 `vb-*` 目录不删；每跑一次全量约留下几十个，2026-09-23 已手动清掉约 6500 个 | 小票：补 `defer` 清理 |
| AI-06 | 观测健康诊断补 Cursor 行 | [06](agent-integration-2026-09/issues/06-cursor-observation-health-row.md) | done（#278） | Cursor 行含 hook / transcript / ACP / cloud 四个来源，没装 hooks 时显示“未安装”；隔离 daemon 快照已验证；设置页界面等协调会话统一重新部署后再看一眼 | — |
| AI-02 | Grok leader 扇出实测、托管会话恢复、`grok -r` 续接 | [02](agent-integration-2026-09/issues/02-grok-leader-fanout-and-recovery.md) | ready-for-agent | 代码里只有 `--no-leader`，没有恢复逻辑 | 保留 |
| AI-03 | Grok status line 转发和活跃会话名册 | [03](agent-integration-2026-09/issues/03-grok-statusline-and-registry.md) | ready-for-agent | 代码里没有对应实现 | 保留 |
| WR-07 | 通知携带 question id，手表横幅回答不再靠推断 | [07](watch-wrist-resolve/issues/07-banner-reply-question-id.md) | needs-triage | Mac 与 iPhone 的推送已带 `questionId`（#248），但手表仍绑定第一份中继状态；ADR-0033 仍把它列为剩余缺口 | 保留，只剩手表侧 |
| D-1 / D-2 | 供应商连接上限到顶时结束通话、一键重拨；语音文档与 ADR-0001 同步 | [02](realtime-verify/issues/02-provider-limit-redial.md) + roadmap JSON | ready-for-agent | 没有重拨代码 | 保留 |
| E-1 | Icon Composer 分层图标 | roadmap JSON `E-1` | 可开工 | 仓库只有 `AppIcon.appiconset` PNG；Xcode 27 已在用，原先的阻塞已解除 | 保留 |
| G-4 | 无障碍检查（VoiceOver / 动态字体 / Reduce Motion），并入 G-5 的设计检查表 | roadmap JSON `G-4` | 部分完成 | Xcode 27 构建和 zh-Hans 已完成，无障碍检查没做 | 缩成只做无障碍 + 检查表 |
| M-07 | 手表展示完整问题 / 审批对象，结果片段可展开 | roadmap JSON `M-07`（按 ADR-0021 2026-09-23 修订缩小） | 可开工 | 不做腕上朗读 | 保留 |
| C-3 / C-5 | 首次运行流程；一等 / 社区级标注 | roadmap JSON | 部分完成 | #224 加了引导清单；README 已标出部分社区适配 | 缩小范围后保留 |
| MAS-09…18 | Mac App Store 沙盒版 | [CHECKLIST](mac-app-store/CHECKLIST.md) | **延后**（代码已丢失，重启时从 09 重做） | 见下节 | 等公开版稳定后再做 |

## 2026-09-23 已拍板（对照 GitHub 同类项目）

| 问题 | 决定 | 依据 | 落在 |
|---|---|---|---|
| History 会话存档 | 删除；重点是实时提醒和进度，保留实时会话阅读 | 你的决定（参考 multica：以任务和提醒为中心，不做全量历史检索）；29.6 GB 索引是 CPU 与磁盘的主因 | #265、ADR-0019/0026/0029 修订 |
| PR 评审 | 独立 Opus 子代理（中等深度），不再用 Grok；评审通过即合并并替换 App | 你的指示 | `docs/agents/pr-review.md` |
| AI-08 hook 分发 | Swift 安装器为主，插件暂不做 | 官方：插件同样被 `allowManagedHooksOnly` 拦截，且装不了主 statusLine；open-vibe-island、CodeIsland、notchi 都用 Swift 直接改配置 | [hook-installer 01](hook-installer/issues/01-swift-hook-installer.md) |
| A-12 / DEC-APNS 公开版推送 | 方向 D：CloudKit 私有库提醒推送，先过原型门槛；自用 `.p8` 保留；打包密钥（A）否决 | 同类项目要么运营持钥服务器（Happy 经 Expo、Home Assistant、Bark），要么不做关 App 推送（CodeIsland 用 BLE）；D 是唯一不运营、不分发密钥的路 | ADR-0013、[public-push 01](public-push/issues/01-cloudkit-alert-push-prototype.md) |
| M-07 / M-09 / M-10 手表 | M-07 缩小后做；M-09 延后；M-10 不做 | Claude 与 Codex 官方都没有手表 App，发起和补充指令都在手机；第三方手表 App 都是"提醒 → 批准 / 回答" | ADR-0021 修订 |
| MAS-15 Codex Desktop 等待提醒 | 维持只观察进度，不承诺等待提醒 | open-vibe-island#506 与我们实测一致；openai/codex#28833 该 hook 会误报 | [15](mac-app-store/issues/15-codex-desktop-remind-only.md) Comments |
| G-5 截图矩阵 | 关闭；检查表并入 G-4 | demo 模式截图（`VIBEBUDDY_DEMO=1`、`tools/watch-qa-shots.sh`、`docs/app-store-screenshots/1.3.17/`）已在用；fastlane snapshot 不支持 macOS | 本表 |

仍需你本人决定的只剩真机验收（下一节）。

## 只能由你在真机上做的验收

- **Codex hook 迁移**（C-1）：在 Mac App 设置里对 Codex 点「修复」，然后在 Codex 的 `/hooks` 里重新信任 VibeBuddy 的 hook。之后 App 更新不再需要重新信任。
- **C-1 干净账户验收**：没有 python3 的账户里一键安装四家、各收到一次真实事件；App 更新后不会重装已卸载的 hook。
- **AI-04 真实会话**（#264 已合并）：本机 `claude` CLI 的 OAuth 已过期。你登录一次后，agent 用隔离 daemon 跑一次真实的 `/loop 1m` 和一个后台 subagent，核对 `background_tasks` 的 `type` / `status` 取值（规则见 CONTEXT.md「Background work at a Claude Stop」）。
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
- hooks 入站审批可行，但 hook 必须走 bundle 内路径，不能带 env 前缀。**注意**：这条结论的依据是已删除的 python `install-codex-hooks.py` 的 `is_forwarder` 检查（命令拆开后正好 2 个 token）。C-1（#266）已改由 Swift `HookInstaller` 按命令识别，并把直接版的 hook 挪到 `~/Library/Application Support/vibebuddy/bin/`；重启商店版时要按新逻辑重新验证，并重新确定沙盒下的 hook 路径与两版共存方式（票 12、14、17）。
- 沙盒里生成子进程运行 CLI 全部失败。
- 商店版不能继承直接版的 Keychain 条目，而且读取可能挂死。

这些结论的出处是 [RESULTS.md](mac-app-store/evidence/RESULTS.md)、[TRIAGE-14-15-17.md](mac-app-store/evidence/triage/TRIAGE-14-15-17.md) 和 [CLAUDE-REVIEW.md](mac-app-store/CLAUDE-REVIEW.md)。`CHECKLIST.md` 链接的两份 HTML 实施手册和探针源码没有复制进仓库，仍在归档包里。审核时可引用已上架的同类沙盒应用 Earcon、SessionRadar、Opsnook 作为先例（见票 18 Comments）。

## 已核实完成、不再列出

通知分类 01–14、观测健康 01–03、手表配额和表盘复杂功能、远程访问 01–03、跨端审计 01–05、手表腕上功能 01/02/03/05（1.3.8）、语音设置重构（#139–#142）、iPhone 第 6–8 轮设计（已由 ADR-0014 取代）、Grok ACP 托管（#233）、Mac App Store 旧票 02–08（已作废）、全部 6 月批次。PR #37、#42、#45、#228、#248 都已合并。未合并就关闭的 #50、#69、#143、#160、#171–#182，其工作都已通过其他 PR 落地。 2026-09-23 当天完成的 #262–#273（AI-04、PERF-01 主因、C-1、AI-05、子进程时限与 fd 继承等）见本文开头「2026-09-23 已完成」。

## 归档位置

- `~/Projects/_shared-work/archive/iOS-vibebuddy-scratch-2026-09-23.tgz`：完整的 `.scratch`，含已完成工单、HTML 计划、探针和证据。
- `~/Projects/_shared-work/archive/iOS-vibebuddy-hidden-refs-2026-09-23.bundle`：Metis 退役备份引用和 Codex 快照引用。
- `~/Projects/_shared-work/archive/iOS-vibebuddy-wip-cueaudience-2026-09-23.bundle`：本地 WIP 标签。
