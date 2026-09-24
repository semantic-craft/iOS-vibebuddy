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

本机环境变化：Claude 与 Grok 的 hook 已迁到固定目录（迁移前的配置备份在 `~/Projects/_shared-work/iOS-vibebuddy/hook-migration-2026-09-23/`）；Codex 仍用旧路径，等你重新信任（2026-09-24 已迁到固定目录，信任前 Codex 的 hook 不运行）。旧 History 索引已删，空间被 13:11 的 Time Machine 本地快照暂时占用，macOS 会自动回收。

### 2026-09-23 晚 · 第二轮（6 个并行会话）

每个会话各自开 PR、经独立 Opus 评审后合并，并同步本表与可交互施工图。**`/Applications` 里仍是 `d43c762b`（#274）的构建**，#275–#281 还没装机；下一步是从 `main` 统一重建替换一次，再做端到端验收和 PERF-01 的长时间测量。

| PR | 改动 | 效果 |
|---|---|---|
| #275 / #279 | **WR-07**：手表横幅回答按通知里的 `questionId` 绑定；换题则不发送，口述留在卡片 | 回答不会落到新问题上（腕上走不到，见 WR-09） |
| #276 | **T-1**：9 个测试文件清理自己建的临时目录 | 全量测试在 `$TMPDIR` 留下的条目 58 → 0 |
| #277 | **C-1b**：安装器与跳转的 7 项评审尾巴全部完成 | 见下表 C-1b 行 |
| #278 | **AI-06**：观测健康诊断加 Cursor 行；诊断尊重 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `CURSOR_HOME` | 设置页能看到 Cursor 的观测状态 |
| #280 | **D-1 / D-2**：语音供应商单次通话上限到顶时结束通话并说明原因，一键重拨；ADR-0001 与文档同步 | 不再静默断线（待真实通话验收） |
| #281 | **PERF-01 启动突发**：首次 token 用量扫描只解析可能计数的行 | 同输入 0–60 s CPU 均值 76% → 8.8% |

仓库状态（2026-09-24，#282 合并后）：没有开放 PR；远端只剩 `main` 与 `gh-pages`；worktree 只剩本协调会话和「AI-04 真机验收准备」会话（AI-04 已于 2026-09-24 验收通过，#284）；「验收」节表里另外三个会话以任务卡片形式待你点开。已完成的会话都已归档。2026-09-23 已删除测试残留：`$TMPDIR` 下约 6500 个 `vb-*` / `recap-*` 等测试临时目录、约 40 个 QA / E2E 用的 `com.vibebuddy.*` 偏好域（保留正式的 `com.vibebuddy.mac`）。

### 2026-09-24 · 装机验收中修掉的性能问题

每个 PR 都经独立 Opus 子代理评审后合并，并从 `main` 重建替换了 `/Applications`（开发版，现为 b07b2dab）。数据见 PERF-01 票 Comments。

| PR | 改动 | 效果 |
|---|---|---|
| #287 | 每个 hook 事件不再把 512 条完成结果重新编码一遍（集合没变就跳过）；Cursor 转录轮询改用 URL resource values，不再读扩展属性 | 活跃时 CPU 下降；Cursor 单次扫描约 12 → 5 ms |
| #290 | App 不再观察模型，菜单栏修饰器不会随每次发布重建（MenuBarExtraAccess 1.3.1 每次重建都会泄漏一组观察者）；新增 `tools/menubar-leak-check.sh` | 2 h 内存从一路上升（193 → 293 MB）变为 254 MB 持平 |
| #293 | 空闲轮询先看界面、后查锁屏；Cursor 解不出的项目名缓存 60 s | 空闲 3.09% → 2.56%（目标 < 2%，转 PERF-02） |

## 开发项

| ID | 内容 | 票据 | 状态 | 依据 | 建议 |
|---|---|---|---|---|---|
| PERF-01 | Mac App 性能收尾 | [01](performance/issues/01-mac-cpu-and-memory.md) | **done**（#265、#281、#287、#290、#293；空闲一项转 PERF-02） | 2026-09-24 装机版三档负载 × 10 min：同负载对比只有 2–3 个 working 一档：8.7% → 6.2%（修复前 4 / 8 个 working 为 10.4% / 11.6%，修复后另两档负载不同）；#287 去掉每个 hook 事件对 512 条完成结果的重复编码，并让 Cursor 轮询不再读扩展属性；#290 修掉菜单栏观察者泄漏（每分钟约 25 组，2 h 内存 193 → 293 MB）；#293 把空闲轮询里的 WindowServer 查询从每轮 266 次降到最多 2 次。修复后 5–6 个 working **6.2%**（目标 < 10%）；2 h 内存（49552ecd，后 90 min 基本空闲）在 254 MB 持平，heap 里泄漏的对象恒为 1；空闲 **2.56%**（目标 < 2%，未达标）。证据在 `~/Projects/_shared-work/iOS-vibebuddy/acceptance-2026-09-24/` | — |
| PERF-02 | Mac App 空闲 CPU 降到 2% 以下 | [02](performance/issues/02-mac-idle-cpu.md) | ready-for-agent | 0 个 working 会话时 2.56%；时间分散在 2 s 快照组装（133 个会话 + 回顾）、Cursor 转录 2 s 轮询、`claude agents` 刷新和 Codex / Cursor 扫描上 | 下一个性能项 |
| A-12 前置 | CloudKit 私有库提醒推送原型 | [01](public-push/issues/01-cloudkit-alert-push-prototype.md) | ready-for-agent | ADR-0013 已选方向 D，需实测延迟与按钮 | 保留，通过后 A-12 按 D 实现 |
| C-1b | 评审留下的小尾巴 | — | done（#277） | ① 后台会话的 jobs 目录尊重 `CLAUDE_CONFIG_DIR`（诊断那半已在 #278 完成）；② `configKey` / manifest key 解析软链，#266 旧 key 下保存的状态栏原件会迁移；③ 旧 manifest / 卸载记录的裸 key 读取时迁移；④ 早期 inline-curl 标记：9876 照旧，其他端口只认当年安装器的原命令，用户自己的本地 webhook 不会被删；⑤ `vibebuddyd hooks install` 先用自身 bundle / checkout 的脚本，再用 `/Applications`，与已装 App 不同时提示；⑥ 跳转查找 3 s 总时限，`/jump` 新分支有测试；⑦ `/ledger/flush` 路由测试，`VIBEBUDDY_PORT` 非法时不发请求，`LedgerFlushRequest` 与 live status 共用无代理 / 无 cookie / 不跟随重定向的会话。全部完成，无跳过 | — |
| T-1 | 测试不清理临时目录 | — | **done**（#276） | 9 个测试文件补 `defer` 清理（`DeviceRegistryTests`、`DevicePushFailureTests`、`EnvironmentDetectorTests`、`TokenConsumptionScanTests`、`ApprovalRoutesTests`、`RecapLedgerTests`、`AttentionTests`、`ClaudeBackgroundLauncherTests`、`CodexAppServerApprovalTests`）；Codex app-server 测试的账本不再写进 `$TMPDIR` 根目录（曾反复覆盖 `tool-ledger.json`）；生产代码无泄漏 | 全量 `swift test` 在 `$TMPDIR` 留下的测试条目 58 → 0，根目录文件不再被改写 |
| AI-06 | 观测健康诊断补 Cursor 行 | [06](agent-integration-2026-09/issues/06-cursor-observation-health-row.md) | done（#278） | Cursor 行含 hook / transcript / ACP / cloud 四个来源；隔离 daemon 快照已验证；2026-09-24 装机版快照里有 Cursor 行：没装 Cursor 显示“未安装”，装了 Cursor 但没装 hook（本机现状）显示“配置不全”，与其他三家规则一致；设置页截图没拍（computer use 未获授权） | — |
| AI-09 | 挂起的 `Stop` 只按已知子代理的 `SubagentStop` 扣减 | [09](agent-integration-2026-09/issues/09-held-stop-known-children.md) | done（#288） | AI-04 验收发现：CLI 内部代理的 `SubagentStop` 没有对应 `SubagentStart`，会先把挂起 `Stop` 的等待计数扣到 0；真正子代理的 `SubagentStart` 丢失时会提前进入 45 s 宽限，后台工作还在跑就提醒完成。现只数结束了已知 running 子代理的 `SubagentStop`，丢了 `SubagentStart` 的轮次由更新的 `Stop` 或 10 分钟兜底释放 | — |
| AI-10 | 转录读取不要覆盖状态行给的上下文窗口和型号 | [10](agent-integration-2026-09/issues/10-transcript-overrides-statusline-window.md) | ready-for-agent | 2026-09-24 验收发现：1M 上下文的 Claude 会话在两次状态行之间显示为 200k 窗口，占用被放大约 5 倍 | 小改动，带回归测试 |
| AI-02 | Grok leader 扇出实测、托管会话恢复、`grok -r` 续接 | [02](agent-integration-2026-09/issues/02-grok-leader-fanout-and-recovery.md) | ready-for-agent | 代码里只有 `--no-leader`，没有恢复逻辑 | 保留 |
| AI-03 | Grok status line 转发和活跃会话名册 | [03](agent-integration-2026-09/issues/03-grok-statusline-and-registry.md) | ready-for-agent | 代码里没有对应实现 | 保留 |
| WR-07 | 通知携带 question id，手表横幅回答不再靠推断 | [07](watch-wrist-resolve/issues/07-banner-reply-question-id.md) | 已合并（#275）；模拟器已验；**腕上走不到** | 绑定逻辑在模拟器上已验过：送达、换题拒绝、多段拒绝、旧通知降级。2026-09-24 腕上验收发现，在 watchOS 27 上点横幅「回复」会直接打开 App，不带文字，所以横幅口述这条路径在真机上根本走不到（见 09） | 等 09 定方案 |
| WR-08 | 手机锁屏时，手表上的「停下」发不出去 | [08](watch-wrist-resolve/issues/08-locked-phone-stop.md) | 代码已完成，待真机：锁屏时停下一次 | 2026-09-24 腕上验收：锁屏时停下没到 Mac，解锁后通过。手表只因中继状态为 `macDisconnected` 就拒绝发送；手机在流断时也不试。#260 已为审批和回答修过同一个误判 | **优先**，修复在分支 `claude/wr08-locked-phone-stop` |
| WR-09 | 手表横幅「回复」直接打开 App，不收文字 | [09](watch-wrist-resolve/issues/09-banner-reply-opens-app.md) | needs-triage | watchOS 27 上，带 `.foreground` 的文字输入按钮不弹输入框；什么都没发出去，是安全的 | 先查 Apple 文档与同类 App，再定方案 |
| WR-10 | 任务详情页「返回总览」点了没反应 | [10](watch-wrist-resolve/issues/10-back-to-dashboard-dead.md) | ready-for-agent | 打开一个已离开列表的会话后出现，只能强制退出；另外列表行上不标 agent | 保留 |
| WR-11 | Mac 只等 25 秒，手表上的操作常常来不及 | [11](watch-wrist-resolve/issues/11-hook-wait-vs-wrist.md) | needs-triage | 这一轮 9 次过期；卡片上还要多点一下「回复」 | 先量时间分布再定 |
| D-1 / D-2 | 供应商连接上限到顶时结束通话、一键重拨；语音文档与 ADR-0001 同步 | [02](realtime-verify/issues/02-provider-limit-redial.md) + roadmap JSON | Kit 层真实通话已验；Mac 界面、iPhone 未验 | 2026-09-24 用 Kit 里 App 共用的 Gemini 会话与通话状态机打真实 API：第 591.9 s 服务端结束通话（按代码只有先收到 `goAway` 才会判为上限），进入「已到上限」且没有报错，重拨 0.8 s 接通。界面上的提示和重拨按钮没截图（computer use 未获授权）；iPhone 路径未验 | — |
| RV-03 | 语音动作不要落到用户没点名的另一个等待中的任务 | [03](realtime-verify/issues/03-voice-action-names-a-different-waiting-task.md) | needs-triage | 2026-09-24 合成语音验收：Qwen 把「拒绝 grape」发成了 `deny_session(orange)`，只因 orange 的卡片刚超时才没落错；现有复核拦不住另一个仍在等待的目标 | 先定方案（转写比对或二次确认），再改 |
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

仍需你本人做的只剩下一节末尾的六件事。

## 验收：agent 自己确认的与只剩你做的

规则（2026-09-24 起）：凡是 agent 能用测试、日志、隔离 daemon、模拟器或 computer use 确认的，都不交给你；要你动手的只留下面六件；有步骤的每件最多 6 步，每步一行。

**agent 在做（各自一个会话，完成后同步本表和可交互施工图）**

| 项 | 怎么确认 | 会话 |
|---|---|---|
| 装机 + 端到端（已完成） | **2026-09-24 通过**：从 `main` 装机 3 次（9137f92f → 49552ecd → b07b2dab，最后一次含 #287、#288、#290、#292、#293）；每次都核对了签名、单进程、`/health`、hook 脚本与仓库一致。隔离 daemon（:18791）17 项全部通过：允许 / 拒绝、问题回答与过期 409、`/device` 403、AI-04 三种情形、Codex / Grok 事件、`/ledger/flush` 204 / 401；跳转查找在已装 App 上 0.49–1.04 s（3 s 时限内）。Codex 已改走固定目录（等同设置页「修复」），`vibebuddyd hooks status` 显示已装、14 条全部等你信任；**信任之前 VibeBuddy 看不到 Codex 会话，也拦不到 Codex 审批**。待办：你信任之后的下一次重新部署，再确认 Codex 仍视 hook 为已信任。设置页截图没拍（computer use 未获授权）。记录在 `~/Projects/_shared-work/iOS-vibebuddy/acceptance-2026-09-24/` | 「Install the latest Mac App and run acceptance」 |
| D-1 真实通话 | **Kit 层已验（2026-09-24）**：无界面的测试程序跑 Kit 里 App 共用的 Gemini 会话，约 10 分钟到上限后正确结束，重拨接通；界面截图未拍。iPhone 路径：模拟器上试过但没走通（未签名的模拟器构建拿不到钥匙串，`-34018`；Xcode 27 的 Device Hub 没有可操作的窗口），改由 agent 用签名的模拟器构建 + XCUITest 点麦克风再走一遍，key 从 `GEMINI_API_KEY` 经测试进程写入，不在界面里输入；尚未做 | 同上 + 「Install the new phone build, then prep the watch check」 |
| PERF-01 收尾（已完成） | 见开发项 PERF-01 行：负载与 2 h 内存达标，空闲转 PERF-02 | 「Install the latest Mac App and run acceptance」 |
| H-2 零漏接 | 在冻结的 1.3.33 候选（之后不再合并）上，用本机真实会话的活动看漏接台账，≥ 30 分钟无新增即算 Mac 端通过。**预跑已通过（2026-09-24，main 9137f92f）**：01:45–03:14Z 共 89 min，本机 2–8 个真实会话在跑，投递 30 条，漏接新增 0；之后的腕上一轮不计入。这次不含 Codex：01:51 起 Codex 的 hook 等你信任、不运行。正式跑之前先做「只剩你」第 3 件，冻结 1.3.33 候选后再跑一次；不能用提交审核代替。手机 / 手表端：2026-09-24 那一轮**没有通过**（锁屏停下失败，另有 2 次推送已被苹果接受但手表没出现），等 WR-08 修好后再判 | 同上（预跑已做） |
| AI-04 真实会话（已完成） | **2026-09-24 通过**，经过见[票 04](agent-integration-2026-09/issues/04-claude-stop-background-tasks.md) Comments 末条：真实 `/loop 1m` 共 7 轮都落定为「已排定循环」，共享 App 的投递记录 0 条；后台 subagent 挂起期间保持 working，结束后 Mac 通知 1 条、APNs 每台手机 1 条。隔离 `vibebuddyd` 不推首次完成提醒，「响没响」只能用菜单栏 App（:9876，`d43c762b`）核对。记录表在 `~/Projects/_shared-work/iOS-vibebuddy/ai04-acceptance-2026-09-23/` | 「VibeBuddy AI-04 真机验收准备」 |
| 路线图旧项的 agent 部分（2026-09-24 上午已跑） | 手机批准（模拟器；Claude、Grok、Cursor）、杀 App 后 APNs、在场门控、`/jump` 接回、Desktop 跳转、派活、手机回答问题、断联待定决策、跨端撤销都通过；D-U 合成语音 Gemini、Qwen 各在第 4 轮 3/3。状态行字段部分通过（被转录覆盖，票 10）；Codex 的 steer、审批和额度推送受阻于 Codex 额度（9 月 25 日 9:00 重置，不用重置券）。另有：验收服务在约定窗口后向 Hermes 多推了 28 条测试提醒。明细与发现见[路线图核对](roadmap-audit-2026-09-24.md)末节 | 本会话；Codex 部分待额度重置后重跑 |
| Hermes / 手表装新版 | **已完成**：2026-09-24 10:45 装到 Hermes；腕上一轮 11:14–12:05 做完，结果见「只剩你」第 1 件。开发版 1.3.28 (58)，`main` 9137f92f（与 ebd06396 应用代码相同），含 #275。**模拟器已验（2026-09-24）**：横幅「回复」带 `questionId` 时持有即绑定并送达，agent 收到的正是那一题；换题后等约 8.6 s 拒绝，卡片显示「这项请求已经不需要你处理了」+「未发送：…」，新题没被答；多段问题不发送、口述留在卡片；无 `questionId` 的旧通知记为 `-unbound`，在首份中继状态绑定后送达；横幅「拒绝」送达，agent 收到 deny。手表在模拟器上不能弹横幅，点击由本地临时注入代替（未提交），点击之后全是正式代码。**D-1 iPhone 未验**：未签名的模拟器构建没有钥匙串权限（`-34018`），存不了 key；Xcode 27 的 Device Hub 没有可操作的模拟器窗口。hook 等待只有 25 s，而手表发出后到 Mac 还要约 11–13 s，所以腕上每步要在横幅到后 10 s 内做完。记录在 `~/Projects/_shared-work/iOS-vibebuddy/watch-acceptance-2026-09-24/RESULTS.md` | 「Install the new phone build, then prep the watch check」 |

**2026-09-24 已由 agent 确认（[路线图核对](roadmap-audit-2026-09-24.md)）**

| 项 | 结果 |
|---|---|
| C-1 干净账户 | **通过（agent 模拟）**：临时 HOME + 去掉 python 的 PATH，`vibebuddyd hooks install` 四家配置与脚本到位；每家一个事件经已装 hook 到隔离 daemon（:18771），四家 hook 诊断 `healthy`；Claude 审批门 allow 返回正常；卸载 Grok 后跑 App 启动刷新（`refreshOnLaunch`，脚本来源换成改过的新 bundle）只更新变了的脚本，Grok 不被装回；真实 `~` 下配置前后 sha256 一致。设置页按钮在 E2E 模式下被故意禁用，它与 CLI 共用 `HookInstaller.install`，且 2026-09-23 本机迁移已用过 |
| 路线图旧项 | E-2 **图标资源层面已覆盖**（现有 PNG 小尺寸可读，E-1 之后重看）；A-03、M-01、D-U、H-1、H-5 **部分覆盖**；B-U 真机证据很少、剩余都可由 agent 做；M-11 范围已过时（M-09 延后、M-10 取消）。只能你做的部分是下面第 2 件，语音耳测是第 4 件 |
| iOS 1.3.28 (58) 审核状态 | **未查到**：没有配置 ASC API key，Chrome 里 App Store Connect 登录已过期（agent 不代为登录），读 Mail / Outlook 的请求被拒绝。最后记录：2026-09-23 03:40 提交、「可供审核」 |

**只剩你（共六件）**

1. **手表一轮：2026-09-24 已做（11:14–12:05），没有全部通过；以后只剩一步：WR-08 修好后，锁屏时从手表停下一次。** 通过的：手机锁屏时，横幅「拒绝」和「批准」；卡片上的快捷回答 + 双指互点两下发送；手机解锁时，从手表「停下」。发现 4 个问题，开了 WR-08 到 WR-11：锁屏时「停下」发不出去（正在修，手表重启后一直显示连不上 Mac 也是这个原因）、横幅「回复」直接打开 App、「返回总览」点了没反应、Mac 只等 25 秒。记录在 `~/Projects/_shared-work/iOS-vibebuddy/watch-acceptance-2026-09-24/RESULTS.md`。
2. **路线图旧项里只有你能做的几步**（手表一轮之后）：
   1. 手机开专注模式，看一条问题横幅还弹不弹（A-03）。
   2. 手机锁屏时在横幅上点批准，看要不要 Face ID（A-03）。
   3. 摘下手表看一条推送落在哪；戴上但不解锁再看一条（M-01）。
   4. 手表上对 Claude、Codex、Grok 各批准一次（H-1）。
   5. 在 Cursor IDE 的 agent 里输入一句提示词（H-5）。
3. **Codex 重新信任**（1 分钟，建议先做）：「修复」已由 agent 做完（2026-09-24 09:51，hook 已指向固定目录）。**在你信任之前，VibeBuddy 看不到 Codex 会话，也拦不到 Codex 的审批。** 在 Codex 里输入 `/hooks`，信任 VibeBuddy 那几条。
4. **三家语音耳测**（约 10 分钟，D-U，只能靠耳朵）：Gemini、Qwen 各打一通短电话，中英文各说一句；OpenAI 补一句英文。每通回一句「听得清吗、能打断吗」。
5. **App Store Connect 登录一次**（1 分钟，可选）：在 Chrome 里登录 appstoreconnect.apple.com，agent 就能读 iOS 1.3.28 (58) 的审核状态。Mail / Outlook 的读取请求你已拒绝，所以也可以直接告诉 agent 状态邮件写的是什么。
6. **要不要发布**：WR-08 修好且锁屏停下复验通过，H-2 也通过后再问你。Mac 1.3.33（带上 #262 起已合并的全部改动，含 #287、#290、#293）和下一版 iOS 是否发布，由你一句话决定；agent 负责打包、公证和上传。

## 观察项（暂不动手）

- **AI-07**：Codex 从 rollout 文件迁到 SQLite 后的降级预案。0.153.4 仍在写 rollout。见 [07](agent-integration-2026-09/issues/07-codex-rollout-degradation.md)。
- **Antigravity hooks**：上游有 bug，已记录在 `docs/multi-cli-hook-setup.md`。
- **Claude `Stop` 里后台任务的类型**：子代理起的后台 shell 与 monitor 都报 `type:"shell"`（TUI 显示「1 shell, 1 monitor」），目前只影响「还有 N 项后台任务」的计数口径，不影响落定规则。三类任务都只见过 `status:"running"`，结束后直接从数组消失；CLI 内部代理的 `SubagentStop` 没有对应的 `SubagentStart`，它们扣减挂起 `Stop` 等待计数的问题已由 AI-09 修复（#288，[票 09](agent-integration-2026-09/issues/09-held-stop-known-children.md)）。

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
