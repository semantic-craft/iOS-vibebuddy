# 施工清单（2026-09-24 更新）

这里是当前全部计划的入口：上半部分是最近已完成的改动，下半部分是**全部未完成**的施工项。可交互版本（带可复制的 agent 提示词）：https://claude.ai/artifact/M4n5cM4CeHYbv7sTGtH6VF 。

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
| #274 | Codex 用量子进程（`CodexAppServerUsageProvider`）同样只继承三个 fd；补回归测试 | 修掉 #272 新测试在全量并发下的偶发失败（Codex 子进程持有了它的管道读端） |

本机环境变化：Claude 与 Grok 的 hook 已迁到固定目录（迁移前的配置备份在 `~/Projects/_shared-work/iOS-vibebuddy/hook-migration-2026-09-23/`）；Codex 仍用旧路径，等你重新信任。旧 History 索引已删，空间被 13:11 的 Time Machine 本地快照暂时占用，macOS 会自动回收。

### 2026-09-23 晚 · 第二轮（6 个并行会话）

每个会话各自开 PR、经独立 Opus 评审后合并，并同步本表与可交互施工图。**`/Applications` 里仍是 `d43c762b`（#274）的构建**，#275–#281 还没装机；下一步是从 `main` 统一重建替换一次，再做端到端验收和 PERF-01 的长时间测量。

| PR | 改动 | 效果 |
|---|---|---|
| #275 / #279 | **WR-07**：手表横幅回答按通知里的 `questionId` 绑定；换题则不发送，口述留在卡片 | 回答不会落到新问题上（待腕上验收） |
| #276 | **T-1**：9 个测试文件清理自己建的临时目录 | 全量测试在 `$TMPDIR` 留下的条目 58 → 0 |
| #277 | **C-1b**：安装器与跳转的 7 项评审尾巴全部完成 | 见下表 C-1b 行 |
| #278 | **AI-06**：观测健康诊断加 Cursor 行；诊断尊重 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `CURSOR_HOME` | 设置页能看到 Cursor 的观测状态 |
| #280 | **D-1 / D-2**：语音供应商单次通话上限到顶时结束通话并说明原因，一键重拨；ADR-0001 与文档同步 | 不再静默断线（待真实通话验收） |
| #281 | **PERF-01 启动突发**：首次 token 用量扫描只解析可能计数的行 | 同输入 0–60 s CPU 均值 76% → 8.8% |

仓库状态（2026-09-24，#282 合并后）：没有开放 PR；远端只剩 `main` 与 `gh-pages`；worktree 只剩本协调会话和「AI-04 真机验收准备」会话（AI-04 已于 2026-09-24 验收通过，#284）；「验收」节表里另外三个会话以任务卡片形式待你点开。已完成的会话都已归档。2026-09-23 已删除测试残留：`$TMPDIR` 下约 6500 个 `vb-*` / `recap-*` 等测试临时目录、约 40 个 QA / E2E 用的 `com.vibebuddy.*` 偏好域（保留正式的 `com.vibebuddy.mac`）。

## 开发项

| ID | 内容 | 票据 | 状态 | 依据 | 建议 |
|---|---|---|---|---|---|
| PERF-01 | Mac App 性能收尾 | [01](performance/issues/01-mac-cpu-and-memory.md) | ready-for-agent（主因已修，#265；启动突发已修，#281） | 稳定后 CPU 均值 2.7%。启动突发的根因不是账本，而是首次 token 用量扫描逐行解析近 8 天约 2 GB 转录；#281 只解析可能计数的行，同输入实测 0–60 s 均值 76% → 8.8%，满载约 52 s → 10 s，45.9 → 5.6 CPU 秒，快照内容不变。待补：三档负载 × 10 min、2 h 内存曲线（全部并行会话合并后在最终版上测） | **优先** |
| A-12 前置 | CloudKit 私有库提醒推送原型 | [01](public-push/issues/01-cloudkit-alert-push-prototype.md) | ready-for-agent | ADR-0013 已选方向 D，需实测延迟与按钮 | 保留，通过后 A-12 按 D 实现 |
| C-1b | 评审留下的小尾巴 | — | done（#277） | ① 后台会话的 jobs 目录尊重 `CLAUDE_CONFIG_DIR`（诊断那半已在 #278 完成）；② `configKey` / manifest key 解析软链，#266 旧 key 下保存的状态栏原件会迁移；③ 旧 manifest / 卸载记录的裸 key 读取时迁移；④ 早期 inline-curl 标记：9876 照旧，其他端口只认当年安装器的原命令，用户自己的本地 webhook 不会被删；⑤ `vibebuddyd hooks install` 先用自身 bundle / checkout 的脚本，再用 `/Applications`，与已装 App 不同时提示；⑥ 跳转查找 3 s 总时限，`/jump` 新分支有测试；⑦ `/ledger/flush` 路由测试，`VIBEBUDDY_PORT` 非法时不发请求，`LedgerFlushRequest` 与 live status 共用无代理 / 无 cookie / 不跟随重定向的会话。全部完成，无跳过 | — |
| T-1 | 测试不清理临时目录 | — | **done**（#276） | 9 个测试文件补 `defer` 清理（`DeviceRegistryTests`、`DevicePushFailureTests`、`EnvironmentDetectorTests`、`TokenConsumptionScanTests`、`ApprovalRoutesTests`、`RecapLedgerTests`、`AttentionTests`、`ClaudeBackgroundLauncherTests`、`CodexAppServerApprovalTests`）；Codex app-server 测试的账本不再写进 `$TMPDIR` 根目录（曾反复覆盖 `tool-ledger.json`）；生产代码无泄漏 | 全量 `swift test` 在 `$TMPDIR` 留下的测试条目 58 → 0，根目录文件不再被改写 |
| AI-06 | 观测健康诊断补 Cursor 行 | [06](agent-integration-2026-09/issues/06-cursor-observation-health-row.md) | done（#278） | Cursor 行含 hook / transcript / ACP / cloud 四个来源，没装 hooks 时显示“未安装”；隔离 daemon 快照已验证；设置页界面等协调会话统一重新部署后再看一眼 | — |
| AI-02 | Grok leader 扇出实测、托管会话恢复、`grok -r` 续接 | [02](agent-integration-2026-09/issues/02-grok-leader-fanout-and-recovery.md) | ready-for-agent | 代码里只有 `--no-leader`，没有恢复逻辑 | 保留 |
| AI-03 | Grok status line 转发和活跃会话名册 | [03](agent-integration-2026-09/issues/03-grok-statusline-and-registry.md) | ready-for-agent | 代码里没有对应实现 | 保留 |
| WR-07 | 通知携带 question id，手表横幅回答不再靠推断 | [07](watch-wrist-resolve/issues/07-banner-reply-question-id.md) | 已合并（#275），待真机验收 | 手表读 `questionId`，持有时即绑定；换题则拒绝并把口述留在卡片（「Use my reply」可改投当前问题）；无 id 的旧通知降级为首份中继状态绑定；ADR-0033 Residual 已改写 | 只剩手腕上验收（见「验收」节第 1 步） |
| D-1 / D-2 | 供应商连接上限到顶时结束通话、一键重拨；语音文档与 ADR-0001 同步 | [02](realtime-verify/issues/02-provider-limit-redial.md) + roadmap JSON | agent 验收中（代码已合入，#280） | Kit 状态机与四家信号映射有测试，两端构建通过；真实通话到上限由 agent 验（见「验收」节） | — |
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

仍需你本人做的只剩下一节末尾的三件事。

## 验收：agent 自己确认的与只剩你做的

规则（2026-09-24 起）：凡是 agent 能用测试、日志、隔离 daemon、模拟器或 computer use 确认的，都不交给你；要你动手的只留下面三件，每件一两步。

**agent 在做（各自一个会话，完成后同步本表和可交互施工图）**

| 项 | 怎么确认 | 会话 |
|---|---|---|
| 装机 + 端到端 | 从 `main` 重建替换 App 一次；隔离 daemon 全流程；设置页 Cursor 行截图（AI-06）；Codex 在设置里点「修复」，你信任之后的下一次重新部署再确认 Codex 仍视 hook 为已信任 | 「Install the latest Mac App and run acceptance」 |
| D-1 真实通话 | Mac 上用 computer use 打一通 Gemini，等约 10 分钟到上限，截图结束提示并点重拨；iPhone 路径在模拟器上同样走一遍（key 用已导出的 `GEMINI_API_KEY` 经启动环境注入，不在界面里输入） | 同上 + 「Install the new phone build, then prep the watch check」 |
| PERF-01 收尾 | 三档负载各 10 分钟 + 2 小时内存曲线（装机后的最终版） | 「Install the latest Mac App and run acceptance」 |
| H-2 零漏接 | 在冻结的 1.3.33 候选（之后不再合并）上，用本机真实会话的活动看漏接台账，≥ 30 分钟无新增即算 Mac 端通过；不能用提交审核代替。手机 / 手表端由下面第 1 步那轮覆盖 | 同上（冻结前先做一次预跑） |
| AI-04 真实会话（已完成） | **2026-09-24 通过**，经过见[票 04](agent-integration-2026-09/issues/04-claude-stop-background-tasks.md) Comments 末条：真实 `/loop 1m` 共 7 轮都落定为「已排定循环」，共享 App 的投递记录 0 条；后台 subagent 挂起期间保持 working，结束后 Mac 通知 1 条、APNs 每台手机 1 条。隔离 `vibebuddyd` 不推首次完成提醒，「响没响」只能用菜单栏 App（:9876，`d43c762b`）核对。记录表在 `~/Projects/_shared-work/iOS-vibebuddy/ai04-acceptance-2026-09-23/` | 「VibeBuddy AI-04 真机验收准备」 |
| C-1 干净账户 | 不新建系统账户：CLI 路径用临时 HOME + 没有 python3 的 PATH；App 一键安装路径（`HookSetup` 用 `NSHomeDirectory()`，不认 `HOME`）用 E2E 运行配置；事件用样例数据触发已装 hook；前后核对真实 `~` 下配置未被改动；卸载后模拟更新不重装 | 「Check old roadmap items and run the C-1 install check without you」 |
| 路线图旧项 A-03、B-U、M-01、M-11、D-U、E-2、H-1、H-5 | 对照历次发布门记录逐项定结论；能验证的当场验证 | 同上 |
| iOS 1.3.28 (58) 审核状态 | 只读查看 App Store Connect（Chrome 登录若已过期，才需要你登录一次） | 同上 |
| Hermes / 手表装新版 | AI-04 跑完后装含 #275 的开发版；能在模拟器上验的（WR-07 绑定与降级文案、ADR-0033 拒绝 / 回答、D-1 iPhone）先验完 | 「Install the new phone build, then prep the watch check」 |

**只剩你（共三件）**

1. **手表一轮**（约 20–30 分钟，可分两次：WR-07 + ADR-0033 一次，WR-06 一次）：agent 装好新版、在 Mac 上发好每道题，一次只给你一步（「手表上点拒绝」这种）。需要你口述、把手机锁屏；触觉能不能分辨由你回一个字；其余结果 agent 在 Mac 上看。真实手腕的结果不用模拟器代替。
2. **Codex 重新信任**（1 分钟）：agent 在设置里点完「修复」后，你在 Codex 里输入 `/hooks`，信任 VibeBuddy 那几条。
3. **要不要发布**：第 1 步和 H-2 通过后再问你。Mac 1.3.33（带上 #262–#281）和下一版 iOS 是否发布，由你一句话决定；agent 负责打包、公证和上传。

## 观察项（暂不动手）

- **AI-07**：Codex 从 rollout 文件迁到 SQLite 后的降级预案。0.153.4 仍在写 rollout。见 [07](agent-integration-2026-09/issues/07-codex-rollout-degradation.md)。
- **Antigravity hooks**：上游有 bug，已记录在 `docs/multi-cli-hook-setup.md`。
- **Claude `Stop` 里后台任务的类型**：子代理起的后台 shell 与 monitor 都报 `type:"shell"`（TUI 显示「1 shell, 1 monitor」），目前只影响「还有 N 项后台任务」的计数口径，不影响落定规则。三类任务都只见过 `status:"running"`，结束后直接从数组消失；CLI 内部代理的 `SubagentStop` 没有对应的 `SubagentStart`，会先扣减挂起 `Stop` 的等待计数，目前靠「仍有 running 子代理」这条检查兜住；若真正子代理的 `SubagentStart` 丢失会提前进入 45 s 宽限，可改为只对已知 running 子代理的 `SubagentStop` 扣减（AI-04 验收发现）。

## Mac App Store：代码已丢失

`CHECKLIST.md` 记的是“09 只差真机 Pairing”，这已经不成立。09 的实现是未提交改动，放在 `~/Projects/iOS-vibebuddy-wt/mac-app-store`（分支 `feat/mac-app-store-watch-approve`）。那个目录、那个分支和相关 stash 都已不存在。在 Git 不可达对象里也没找到 `BuildChannel` / `DaemonPort`，`main` 上没有商店 target。

还留着的是产品与技术结论，重做时直接沿用：

- 沙盒里连接 Codex socket 会报 EPERM（死路）。
- hooks 入站审批可行，但 hook 必须走 bundle 内路径，不能带 env 前缀。**注意**：这条结论的依据是已删除的 python `install-codex-hooks.py` 的 `is_forwarder` 检查（命令拆开后正好 2 个 token）。C-1（#266）已改由 Swift `HookInstaller` 按命令识别，并把直接版的 hook 挪到 `~/Library/Application Support/vibebuddy/bin/`；重启商店版时要按新逻辑重新验证，并重新确定沙盒下的 hook 路径与两版共存方式（票 12、14、17）。
- 沙盒里生成子进程运行 CLI 全部失败。
- 商店版不能继承直接版的 Keychain 条目，而且读取可能挂死。

这些结论的出处是 [RESULTS.md](mac-app-store/evidence/RESULTS.md)、[TRIAGE-14-15-17.md](mac-app-store/evidence/triage/TRIAGE-14-15-17.md) 和 [CLAUDE-REVIEW.md](mac-app-store/CLAUDE-REVIEW.md)。`CHECKLIST.md` 链接的两份 HTML 实施手册和探针源码没有复制进仓库，仍在归档包里。审核时可引用已上架的同类沙盒应用 Earcon、SessionRadar、Opsnook 作为先例（见票 18 Comments）。

## 已核实完成、不再列出

通知分类 01–14、观测健康 01–03、手表配额和表盘复杂功能、远程访问 01–03、跨端审计 01–05、手表腕上功能 01/02/03/05（1.3.8）、语音设置重构（#139–#142）、iPhone 第 6–8 轮设计（已由 ADR-0014 取代）、Grok ACP 托管（#233）、Mac App Store 旧票 02–08（已作废）、全部 6 月批次。PR #37、#42、#45、#228、#248 都已合并。未合并就关闭的 #50、#69、#143、#160、#171–#182，其工作都已通过其他 PR 落地。 2026-09-23 完成的 #262–#281（AI-04、PERF-01、C-1/C-1b、AI-05、AI-06、T-1、WR-07、D-1/D-2 与子进程时限等）见本文开头「2026-09-23 已完成」。

## 归档位置

- `~/Projects/_shared-work/archive/iOS-vibebuddy-scratch-2026-09-23.tgz`：完整的 `.scratch`，含已完成工单、HTML 计划、探针和证据。
- `~/Projects/_shared-work/archive/iOS-vibebuddy-hidden-refs-2026-09-23.bundle`：Metis 退役备份引用和 Codex 快照引用。
- `~/Projects/_shared-work/archive/iOS-vibebuddy-wip-cueaudience-2026-09-23.bundle`：本地 WIP 标签。
