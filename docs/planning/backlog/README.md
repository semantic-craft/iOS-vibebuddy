# 施工清单（2026-09-25 更新）

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

本机环境变化：Claude 与 Grok 的 hook 已迁到固定目录（迁移前的配置备份在 `~/Projects/_shared-work/iOS-vibebuddy/hook-migration-2026-09-23/`）；当时 Codex 仍用旧路径（2026-09-24 已迁到固定目录，你已信任，`vibebuddyd hooks status` 显示 14 条 hook 全部运行）。旧 History 索引已删，空间被 13:11 的 Time Machine 本地快照暂时占用，macOS 会自动回收。

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
| #300 | **PERF-02**：Cursor 转录改由 FSEvents 唤醒（仍至少间隔 2 s，另有 30 s 兜底）；回顾只为 24 h 内最新 12 条建条目（输出不变，快照组装仍然每次都做）；数据库签名、Codex 目录检查改用 stat / lstat；漏看周标签不再每次新建 `DateFormatter` | 装机版空闲（0 个 working，10 min）2.56% → **1.50%**；隔离 A/B 2.13% → 1.71%；Cursor 状态各测了一次：0.77 s 变为 working、0.10 s 变为 done（原来固定 2 s 轮询一次），连续写入时仍至少间隔 2 s 处理一次 |

### 2026-09-24 至 25 · 手表腕上问题（WR-08…WR-12）

每个 PR 都经独立 Opus 子代理评审，修完意见后合并。

| PR | 改动 | 效果 |
|---|---|---|
| #292 | **WR-08**：手机锁屏、流断时，手表的「停下」照样发出；手机拿 Mac 的快照核对后试一次，不排队、不重试 | **腕上已过（2026-09-25 15:45:50 +08:00）**：手机到 Mac 的连接应是断的（按停下前后两次提醒推断），从手表停下托管 Cursor 任务，Mac 记为 `userStopped`（锁屏按操作步骤推断） |
| #303 | **WR-10**：「返回总览」由 store 直接关详情页；新诊断 `detail.back` / `detail.dismissed` / `route.url.*`，诊断环 48 → 200 条；列表行标出 agent | 模拟器上没复现真机那次的问题，6 种顺序都能返回（属防护性修复）；腕上 2026-09-25 19:00:55 点「返回总览」0.6 s 关页（测的是列表内任务，任务离开列表的原故障场景只在模拟器测过） |
| #305 | **WR-09**：手表上的「回复」就是打开回答卡片；诊断分清系统给的是 nil 还是空文字；ADR-0033 修订 | 腕上 2026-09-25 19:04:58 通过：横幅「回复」进卡片，提问后 12.4 s 模拟的 Claude hook 收到「Yes」 |
| #304 | **WR-11**：Mac 前没人时，Claude 的审批和提问最多等 60 s（原 25 s），等待中每秒重判一次，回到终端就交还 CLI；hook 超时 75 s；Grok compat 不再执行 Claude 的审批门 | 2026-09-25 装机后 Mac 端验证：daemon 按 hold=60 等满 60.3 s（测试直接调 `/approval`，未经 hook 脚本；已装 hook 配置为 `claude 60` / timeout 75）；第 35 s 用手机的 `/answer` 格式作答，模拟 hook 在 35.3 s 收到；腕上超过 25 s 的作答未直接测 |
| #309 | **WR-12**：手表回到前台（或前台时手机变为可达）就向手机要一次最新状态，限频 | 腕上 2026-09-25 通过：手机锁屏后新开的任务，第二次抬腕请求后 1.3 s 收到，手机同步给手表的状态里有这条任务 |

## 开发项

| ID | 内容 | 票据 | 状态 | 依据 | 建议 |
|---|---|---|---|---|---|
| PERF-01 | Mac App 性能收尾 | [01](performance/issues/01-mac-cpu-and-memory.md) | **done**（#265、#281、#287、#290、#293；空闲一项转 PERF-02） | 2026-09-24 装机版三档负载 × 10 min：同负载对比只有 2–3 个 working 一档：8.7% → 6.2%（修复前 4 / 8 个 working 为 10.4% / 11.6%，修复后另两档负载不同）；#287 去掉每个 hook 事件对 512 条完成结果的重复编码，并让 Cursor 轮询不再读扩展属性；#290 修掉菜单栏观察者泄漏（每分钟约 25 组，2 h 内存 193 → 293 MB）；#293 把空闲轮询里的 WindowServer 查询从每轮 266 次降到最多 2 次。修复后 5–6 个 working **6.2%**（目标 < 10%）；2 h 内存（49552ecd，后 90 min 基本空闲）在 254 MB 持平，heap 里泄漏的对象恒为 1；空闲 **2.56%**（目标 < 2%，未达标）。证据在 `~/Projects/_shared-work/iOS-vibebuddy/acceptance-2026-09-24/` | — |
| PERF-02 | Mac App 空闲 CPU 降到 2% 以下 | [02](performance/issues/02-mac-idle-cpu.md) | **done**（#300；空闲达标；负载、2 h 内存和审批延迟没有复测，按推理豁免） | 装机版（main 含 #300、#301），0 个 working 会话，10 min：**1.50%**（p95 2.6%）。修复前 2.56%。原因：Cursor 转录每 2 s 全量列目录并 stat；每次快照把一周约 1550 条回顾全部建成条目。证据在 `~/Projects/_shared-work/iOS-vibebuddy/perf-02-2026-09-24/` | 活跃时每个 hook 事件都整份写回日志和最近目录，可另开票 |
| A-12 前置 | CloudKit 私有库提醒推送原型 | [01](public-push/issues/01-cloudkit-alert-push-prototype.md) | ready-for-agent | ADR-0013 已选方向 D，需实测延迟与按钮 | 保留，通过后 A-12 按 D 实现 |
| C-1b | 评审留下的小尾巴 | — | done（#277） | ① 后台会话的 jobs 目录尊重 `CLAUDE_CONFIG_DIR`（诊断那半已在 #278 完成）；② `configKey` / manifest key 解析软链，#266 旧 key 下保存的状态栏原件会迁移；③ 旧 manifest / 卸载记录的裸 key 读取时迁移；④ 早期 inline-curl 标记：9876 照旧，其他端口只认当年安装器的原命令，用户自己的本地 webhook 不会被删；⑤ `vibebuddyd hooks install` 先用自身 bundle / checkout 的脚本，再用 `/Applications`，与已装 App 不同时提示；⑥ 跳转查找 3 s 总时限，`/jump` 新分支有测试；⑦ `/ledger/flush` 路由测试，`VIBEBUDDY_PORT` 非法时不发请求，`LedgerFlushRequest` 与 live status 共用无代理 / 无 cookie / 不跟随重定向的会话。全部完成，无跳过 | — |
| T-1 | 测试不清理临时目录 | — | **done**（#276） | 9 个测试文件补 `defer` 清理（`DeviceRegistryTests`、`DevicePushFailureTests`、`EnvironmentDetectorTests`、`TokenConsumptionScanTests`、`ApprovalRoutesTests`、`RecapLedgerTests`、`AttentionTests`、`ClaudeBackgroundLauncherTests`、`CodexAppServerApprovalTests`）；Codex app-server 测试的账本不再写进 `$TMPDIR` 根目录（曾反复覆盖 `tool-ledger.json`）；生产代码无泄漏 | 全量 `swift test` 在 `$TMPDIR` 留下的测试条目 58 → 0，根目录文件不再被改写 |
| AI-06 | 观测健康诊断补 Cursor 行 | [06](agent-integration-2026-09/issues/06-cursor-observation-health-row.md) | done（#278） | Cursor 行含 hook / transcript / ACP / cloud 四个来源；隔离 daemon 快照已验证；2026-09-24 装机版快照里有 Cursor 行：没装 Cursor 显示“未安装”，装了 Cursor 但没装 hook（本机现状）显示“配置不全”，与其他三家规则一致；设置页截图没拍（computer use 未获授权） | — |
| AI-09 | 挂起的 `Stop` 只按已知子代理的 `SubagentStop` 扣减 | [09](agent-integration-2026-09/issues/09-held-stop-known-children.md) | done（#288） | AI-04 验收发现：CLI 内部代理的 `SubagentStop` 没有对应 `SubagentStart`，会先把挂起 `Stop` 的等待计数扣到 0；真正子代理的 `SubagentStart` 丢失时会提前进入 45 s 宽限，后台工作还在跑就提醒完成。现只数结束了已知 running 子代理的 `SubagentStop`，丢了 `SubagentStart` 的轮次由更新的 `Stop` 或 10 分钟兜底释放 | — |
| AI-10 | 转录读取不要覆盖状态行给的上下文窗口和型号 | [10](agent-integration-2026-09/issues/10-transcript-overrides-statusline-window.md) | done（#296） | 2026-09-24 验收发现：1M 上下文的 Claude 会话在两次状态行之间显示为 200k 窗口，占用被放大约 5 倍。现在状态行报过的型号和窗口不再被转录覆盖，转录只更新 token 数；模型切换后转录可以重新补。回归测试先红后绿；隔离 daemon 快照为 1M / 显示名 / token 40039 | 真实 1M 会话随下次装机复看 |
| AI-02 | Grok leader 扇出实测、托管会话恢复、`grok --resume` 续接 | [02](agent-integration-2026-09/issues/02-grok-leader-fanout-and-recovery.md) | done（#299） | 实测：leader 模式下第二个客户端能看到 TUI 会话、同时收到它的权限请求，且它的回答能直接放行 TUI 的提示；关掉 TUI 后回合在 leader 里继续、不发 `SessionEnd`；文件 hook `timeout` 没有 600 s 上限（1 800 s 才被截断）。恢复：daemon 重启后托管会话显示为可恢复，继续时 `session/load` 接上（真实 grok 记得重启前的对话）；失败给出原因，在 Mac 上打开这一行会在终端 `grok --resume` 续接 | leader 挂接（远程批准终端里的 Grok）可行但没做，要做另开票 |
| AI-03 | Grok status line 转发和活跃会话名册 | [03](agent-integration-2026-09/issues/03-grok-statusline-and-registry.md) | done（#298） | 安装时包装 `[ui.status_line]`（卸载按字节还原）；Grok 行显示上下文与成本（真实 TUI：21.5k / 500k、$0.038）；`kill -9` 关掉 TUI 后 16 s 由名册兜底移出 working，正常关闭由 `SessionEnd` 约 1 s 移除 | 新会话生效；你的 `~/.grok/config.toml` 要在 App 里点 Install / repair 后才会改 |
| WR-07 | 通知携带 question id，手表横幅回答不再靠推断 | [07](watch-wrist-resolve/issues/07-banner-reply-question-id.md) | done（#275） | 绑定逻辑在模拟器上已验过：送达、换题拒绝、多段拒绝、旧通知降级。watchOS 27 上点横幅「回复」直接打开 App、不带文字，横幅口述走不到；09 已定为打开回答卡片 | 绑定代码保留，只在某个 watchOS 带来文字时生效；横幅口述的真机验收不再追 |
| WR-08 | 手机锁屏时，手表上的「停下」发不出去 | [08](watch-wrist-resolve/issues/08-locked-phone-stop.md) | **done**（#292，腕上 2026-09-25 通过；锁屏未经你确认） | 2026-09-25 15:45:50：手表停下托管 Cursor 任务（当时锁屏为推断），Mac 记为 `userStopped`、`sleep 900` 同时结束（`~/Projects/_shared-work/iOS-vibebuddy/watch-round-2026-09-25/RESULTS.md`，构建 main 2031998b，含 #292）。同一轮发现 WR-12 候选。停下前后（15:44:34、15:48:41 两次提醒）手机都没有回执，全部经 APNs；流在线时手机会先回执、Mac 跳过一条 APNs（如 19:03:28），所以停下时的连接应是断的，这正是 WR-08 修的故障条件。当天 00:50–18:56 全天都没有手机回执，这条记录说明不了是否锁屏；锁屏按操作步骤推断，未经你确认 | — |
| WR-09 | 手表横幅「回复」直接打开 App，不收文字 | [09](watch-wrist-resolve/issues/09-banner-reply-opens-app.md) | **done**（#305，腕上 2026-09-25 19:04 通过） | 定案：手表上「回复」就是打开回答卡片（卡片路径 2026-09-24 已在真机跑通）；手机照旧内联回复。诊断记为 `notification.action-reply-card.*`，顺带分清系统给的是 nil 还是空文字 | 腕上：横幅「回复」→ `notification.action-reply-card.no-text-response` → 卡片 → 「Yes」，提问后 12.4 s，模拟的 Claude hook 收到 `{"Ship the release now?":"Yes"}`（`~/Projects/_shared-work/iOS-vibebuddy/watch-round-2026-09-25/RESULTS.md`） |
| WR-10 | 任务详情页「返回总览」点了没反应 | [10](watch-wrist-resolve/issues/10-back-to-dashboard-dead.md) | **done**（#303；腕上测的是列表内任务，离开列表的情形只在模拟器测过） | 模拟器上没复现真机那次的问题（6 种顺序都能返回）；改为 store 直接关页（防护性），新诊断能分清是按钮没收到点击还是页面卡住；列表行已标出 agent | 腕上：详情页点「返回总览」→ `detail.back` → 0.6 s 后 `detail.dismissed`（`~/Projects/_shared-work/iOS-vibebuddy/watch-round-2026-09-25/RESULTS.md`） |
| WR-11 | Mac 只等 25 秒，手表上的操作常常来不及 | [11](watch-wrist-resolve/issues/11-hook-wait-vs-wrist.md) | **done**（#304；Mac 端验证，腕上超过 25 s 未直接测；Claude hook 已是 `claude 60` / timeout 75） | 实测：横幅批准 / 拒绝 5–9 s 到 Mac；卡片回答 16–25 s 以上（真机只完整量到一次，20.1 s），压线。9 次过期里只有 3 次是时间不够，其余是没弹横幅、没震、没戴表等。定案：Mac 前没人时 Claude 等到 60 s，等待中每秒重判 presence；Codex / Cursor / Grok 与旧配置仍 25 s | 2026-09-25 已装 App 上验证：daemon 按 hold=60 等满 60.3 s 才放行（原 25 s；测试直接调 `/approval`，未经 hook 脚本）；第 35 s 用手机的 `/answer` 格式作答，模拟 hook 在 35.3 s 收到。腕上作答走同一个 `/answer`（`DecisionClient.swift`），所以腕上超过 25 s 能送到是推断，未直接测。已知遗留：Esc 中断后卡片最多还能答 60 s（回答会被丢掉），可另开票 |
| WR-12 | 手机锁屏时，新开的任务到不了手表 | [12](watch-wrist-resolve/issues/12-new-task-while-phone-locked.md) | **done**（#309，腕上 2026-09-25 18:56 通过） | 2026-09-25 14:57–15:27 打开手表 App 4 次都没看到锁屏后才开始的任务，没法停下。`WatchStateStore.becameActive()` 只重读 application context；锁屏手机的流已断、不写新 context。修法：手表回到前台（或前台时手机变为可达）就向手机要一次最新状态，限频（成功后 15 s、失败后 3 s），装入时不震 | 腕上：手机锁屏后在 Mac 上开 Grok 任务，第一次抬腕 2 s 内请求失败；第二次抬腕，请求后 1.3 s 收到，手机同步给手表的状态里有这条任务。限制：抬腕头 1–2 s 手机常还不可达，那次刷新失败，窗口关了就不再重试，只瞄一眼就放下时仍看到旧列表，再抬一次即可（不另开票） |
| D-1 / D-2 | 供应商连接上限到顶时结束通话、一键重拨；语音文档与 ADR-0001 同步 | [02](realtime-verify/issues/02-provider-limit-redial.md) + roadmap JSON | **代码完成**；Gemini 路径 2026-09-25 由你取消，iPhone 的 D-1 检查不再需要；Mac / iPhone 上的到顶提示和重拨按钮没截图验证过，等自然出现的长通话再看 | 2026-09-25 你决定移除 Gemini 集成（ADR-0001 修订），唯一能在约 10 分钟内到顶的供应商随之移除；结束通话 + 重拨保留给 Qwen / OpenAI（按单元测试，真实到顶要 60–120 分钟，碰上长通话时再看）。历史：2026-09-24 用 Kit 里 App 共用的 Gemini 会话与通话状态机打真实 API：第 591.9 s 服务端结束通话（按代码只有先收到 `goAway` 才会判为上限），进入「已到上限」且没有报错，重拨 0.8 s 接通。界面上的提示和重拨按钮没截图（computer use 未获授权）；iPhone 路径未验 | — |
| RV-03 | 语音动作不要落到用户没点名的另一个等待中的任务 | [03](realtime-verify/issues/03-voice-action-names-a-different-waiting-task.md) | 已合并（#297） | 2026-09-24 定案：批准、拒绝、回答、指示这四种动作，只有用户这一句话里说出了目标的名字才会发出；没说就扣住，请用户说出名字（ADR-0008「Named target」）。单元测试复现了 grape→orange；修复后用 Qwen、Gemini 合成语音重跑，点名的动作都落对了，没有落到别的任务上；Gemini 把「橘子」转写成日文，误扣过一次（安全方向）。已知缺口：Live 的工具调用如果比新一句的转写先到，上一句的词还算数（Gemini 的同一缺口随 2026-09-25 移除 Gemini 成为历史） | 真机语音时留意有没有误扣 |
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

仍需你本人做的见下一节末尾（剩四件）。

## 验收：agent 自己确认的与只剩你做的

规则（2026-09-24 起）：凡是 agent 能用测试、日志、隔离 daemon、模拟器或 computer use 确认的，都不交给你；要你动手的只留下面六件；有步骤的每件最多 6 步，每步一行。

**agent 在做（各自一个会话，完成后同步本表和可交互施工图）**

| 项 | 怎么确认 | 会话 |
|---|---|---|
| 装机 + 端到端（已完成） | **2026-09-24 通过**：从 `main` 装机 3 次（9137f92f → 49552ecd → b07b2dab，最后一次含 #287、#288、#290、#292、#293）；每次都核对了签名、单进程、`/health`、hook 脚本与仓库一致。隔离 daemon（:18791）17 项全部通过：允许 / 拒绝、问题回答与过期 409、`/device` 403、AI-04 三种情形、Codex / Grok 事件、`/ledger/flush` 204 / 401；跳转查找在已装 App 上 0.49–1.04 s（3 s 时限内）。Codex 已改走固定目录（等同设置页「修复」），`vibebuddyd hooks status` 显示已装、14 条当时等你信任（2026-09-24 你已信任，现在全部运行）；信任之前 Codex 的 hook 事件和命令行审批拦截不运行（已信任，此限制已解除）；会话和进度仍经 app-server / 转录看得到。2026-09-24 重新部署后已确认 Codex 仍视为已信任（见 C-1 票）。设置页截图没拍（computer use 未获授权）。记录在 `~/Projects/_shared-work/iOS-vibebuddy/acceptance-2026-09-24/` | 「Install the latest Mac App and run acceptance」 |
| D-1 真实通话 | **2026-09-25 取消**：Gemini 集成已移除，iPhone 这一步不再做。历史：**Kit 层已验（2026-09-24）**：无界面的测试程序跑 Kit 里 App 共用的 Gemini 会话，约 10 分钟到上限后正确结束，重拨接通；界面截图未拍。iPhone 路径：模拟器上试过但没走通（未签名的模拟器构建拿不到钥匙串，`-34018`；Xcode 27 的 Device Hub 没有可操作的窗口），改由 agent 用签名的模拟器构建 + XCUITest 点麦克风再走一遍，key 从 `GEMINI_API_KEY` 经测试进程写入，不在界面里输入；尚未做 | 同上 + 「Install the new phone build, then prep the watch check」 |
| PERF-01 收尾（已完成） | 见开发项 PERF-01 行：负载与 2 h 内存达标，空闲转 PERF-02 | 「Install the latest Mac App and run acceptance」 |
| H-2 零漏接 | 在冻结的 1.3.33 候选（之后不再合并）上，用本机真实会话的活动看漏接台账，≥ 30 分钟无新增即算 Mac 端通过。**预跑已通过（2026-09-24，main 9137f92f）**：01:45–03:14Z 共 89 min，本机 2–8 个真实会话在跑，整段漏接新增 0（其中 01:45–02:35 读到 10 次提醒、共 30 条投递记录）；之后的腕上一轮不计入。这次不含 Codex 的 hook 事件：01:51 起它们等你信任、不运行（之后你已信任，正式跑会包含）。正式跑之前先做「只剩你」第 3 件，冻结 1.3.33 候选后再跑一次；不能用提交审核代替。手机 / 手表端：2026-09-24 那一轮**没有通过**（锁屏停下失败，另有 2 次推送已被苹果接受但手表没出现）；2026-09-25 手表检查已完成（连接应已断开时停下、锁屏后新任务、回复进卡片、返回总览都过了），手机 / 手表端不再阻塞 H-2（晚上这一轮没有逐条核对推送是否都到了手表）；2026-09-24 那 2 次「苹果已接受但手表没出现」原因未查明，列为观察，再出现再查。Mac 端正式跑 **2026-09-25 通过**：19:09:11–19:40:48（31.6 min），已装 `main` 6236e188（期间 main 只合并了文档），漏接台账新增 0；期间 4 个真实会话共 5 次完成提醒，每次本机通知 + APNs 两台都被接受；这段时间没有出现等待你回应的请求，所以只证明了没有误记和投递正常，没考到「等待没人回应」。记录在 `~/Projects/_shared-work/iOS-vibebuddy/h2-2026-09-25/RESULT.md` | 同上（预跑已做） |
| AI-04 真实会话（已完成） | **2026-09-24 通过**，经过见[票 04](agent-integration-2026-09/issues/04-claude-stop-background-tasks.md) Comments 末条：真实 `/loop 1m` 共 7 轮都落定为「已排定循环」，共享 App 的投递记录 0 条；后台 subagent 挂起期间保持 working，结束后 Mac 通知 1 条、APNs 每台手机 1 条。隔离 `vibebuddyd` 不推首次完成提醒，「响没响」只能用菜单栏 App（:9876，`d43c762b`）核对。记录表在 `~/Projects/_shared-work/iOS-vibebuddy/ai04-acceptance-2026-09-23/` | 「VibeBuddy AI-04 真机验收准备」 |
| 路线图旧项的 agent 部分（2026-09-24 上午已跑） | 手机批准（模拟器；Claude、Grok、Cursor）、杀 App 后 APNs、在场门控、`/jump` 接回、Desktop 跳转、派活、手机回答问题、断联待定决策、跨端撤销都通过；D-U 合成语音 Gemini、Qwen 各在第 4 轮 3/3。状态行字段部分通过（被转录覆盖，票 10）；Codex 的 steer、审批和额度推送受阻于 Codex 额度（9 月 25 日 9:00 重置，不用重置券）。另有：验收服务在约定窗口后向 Hermes 多推了 28 条测试提醒。明细与发现见[路线图核对](roadmap-audit-2026-09-24.md)末节 | 本会话；Codex 审批 2026-09-25 已验（托管任务），steer、额度推送未重跑 |
| Hermes / 手表装新版 | **2026-09-25 18:4x（+08:00）三台都装 `main` 6236e188**：Hermes 与手表经 devicectl（开发版 1.3.28 (58)），Mac 经 `tools/redeploy-mac.sh`（/Applications，pid 85118）；Mac `apns.json` 仍是 sandbox。之前的记录：`~/Projects/_shared-work/iOS-vibebuddy/watch-acceptance-2026-09-24/RESULTS.md`、`watch-round-2026-09-25/RESULTS.md` | 本会话 |

**2026-09-24 已由 agent 确认（[路线图核对](roadmap-audit-2026-09-24.md)）**

| 项 | 结果 |
|---|---|
| C-1 干净账户 | **通过（agent 模拟）**：临时 HOME + 去掉 python 的 PATH，`vibebuddyd hooks install` 四家配置与脚本到位；每家一个事件经已装 hook 到隔离 daemon（:18771），四家 hook 诊断 `healthy`；Claude 审批门 allow 返回正常；卸载 Grok 后跑 App 启动刷新（`refreshOnLaunch`，脚本来源换成改过的新 bundle）只更新变了的脚本，Grok 不被装回；真实 `~` 下配置前后 sha256 一致。设置页按钮在 E2E 模式下被故意禁用，它与 CLI 共用 `HookInstaller.install`，且 2026-09-23 本机迁移已用过 |
| 路线图旧项 | E-2 **图标资源层面已覆盖**（现有 PNG 小尺寸可读，E-1 之后重看）；A-03、M-01、D-U、H-1、H-5 **部分覆盖**；B-U 真机证据很少、剩余都可由 agent 做；M-11 范围已过时（M-09 延后、M-10 取消）。只能你做的部分是下面第 2 件，语音耳测是第 4 件 |
| iOS 1.3.28 (58) 审核状态 | **未查到**：没有配置 ASC API key，Chrome 里 App Store Connect 登录已过期（agent 不代为登录），读 Mail / Outlook 的请求被拒绝。最后记录：2026-09-23 03:40 提交、「可供审核」 |

**只剩你（原六件，剩四件：第 2、4、5、6 件）**

1. ~~**手表检查**~~ **已完成（2026-09-25 18:53–19:07）**：锁屏后新开的任务出现在手表上（WR-12）、「回复」进卡片作答（WR-09）、「返回总览」（WR-10，测的是列表内任务）在腕上通过。WR-11 由 agent 在已装 App 上验证：等满 60 s，第 35 s 的回答送到；腕上超过 25 s 未直接测。WR-08：停下时手机到 Mac 的连接应是断的（按停下前后两次提醒的投递记录推断），锁屏按操作步骤推断。H-1 Codex 由 agent 用托管 Codex 任务验过：APNs 已接受这条批准推送，经手机用的同一接口批准后 Codex 执行了命令；手表到 Mac 这一段不分 agent。发现并修好一个环境问题：Codex 共享 app-server 守护进程还跑着 9 月 20 日的 0.153.4，自动升级删掉了它的 `codex-code-mode-host`，派给 Codex 的任务执行不了任何命令；已用 `codex app-server daemon start` 换成受管的 0.156.1。记录在 `~/Projects/_shared-work/iOS-vibebuddy/watch-round-2026-09-25/RESULTS.md`。
2. **路线图旧项里只有你能做的两步**（可选，手表检查之后）：
   1. 手机锁屏时在横幅上点批准，看要不要 Face ID（A-03）。
   2. 在 Cursor IDE 的 agent 里输入一句提示词（H-5）。

   2026-09-25 删掉了三步。专注模式下横幅弹不弹（A-03）：我们发的是 `interruption-level: time-sensitive` 并申请了对应 entitlement，负载有测试覆盖（`ActivityPushTests`、`NotificationDeliveryTests`），Mac 的专注模式 2026-09-06 已验，iPhone 上的表现取决于你自己的专注设置。摘下手表时推送落在哪（M-01）：由系统决定。手表上对三家各批准一次（H-1）：手表到手机到 Mac 这一段不分 agent，手表批准已过 3 次（2 次模拟的 Claude 等待、1 次托管 Cursor）；各家 Mac 端由 agent 验，Claude、Grok、Cursor 已在模拟器通过，Codex 2026-09-25 已由 agent 验过（托管任务，见第 1 件）。
3. ~~**Codex 重新信任**~~ **已完成**（2026-09-24）：你已在 `/hooks` 信任，`vibebuddyd hooks status` 显示「Codex is running all 14 VibeBuddy hooks」，路径是固定目录。重新部署后已确认：两次从 main 替换 App 之后（11:00Z、12:08Z），`hooks status` 仍显示「running all 14」，不需要重新信任。
4. **语音耳测**（约 5 分钟，D-U，只能靠耳朵）：Qwen 打一通短电话，中英文各说一句；OpenAI 补一句英文（Gemini 已于 2026-09-25 移除）。每通回一句「听得清吗、能打断吗」。
5. **App Store Connect 登录一次**（1 分钟，可选）：在 Chrome 里登录 appstoreconnect.apple.com，agent 就能读 iOS 1.3.28 (58) 的审核状态。Mail / Outlook 的读取请求你已拒绝，所以也可以直接告诉 agent 状态邮件写的是什么。
6. **要不要发布**：手表检查（第 1 件）和 H-2 都通过后再问你。Mac 1.3.33（带上 #262 起已合并的全部改动，含 #287、#290、#293）和下一版 iOS 是否发布，由你一句话决定；agent 负责打包、公证和上传。下一版起已没有 Gemini：发布或提交审核时，agent 同步删掉 `docs/privacy-policy.md` 和 `docs/app-store-listing.md` 里的 Google (Gemini)。

## 观察项（暂不动手）

- **AI-07**：Codex 从 rollout 文件迁到 SQLite 后的降级预案。0.153.4 仍在写 rollout（2026-09-25 共享 daemon 已换成 0.156.1，待核实）。见 [07](agent-integration-2026-09/issues/07-codex-rollout-degradation.md)。
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
