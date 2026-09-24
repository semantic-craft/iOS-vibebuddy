# 02: Mac App 空闲 CPU 降到 2% 以下

**Status:** done（#300；空闲目标达标，装机版 1.50%。负载、2 h 内存和审批延迟三项没有复测，只按推理豁免，理由见 Comments）

**Blocked by:** None

## 为什么

PERF-01 收尾后负载和内存都达标：5–6 个 working 会话时 CPU 均值 6.2%，2 h 内存曲线在 254 MB 持平（两项都在 main 49552ecd 上测）。最终装机 main b07b2dab（含 #293）。只有空闲一项没达标：本机 0 个 working 会话、10 min、启动后等待 ≥ 90 s，CPU 均值 **2.56%**、p95 4.2%，目标 < 2%。#293 修复前是 3.09%。证据在 `~/Projects/_shared-work/iOS-vibebuddy/acceptance-2026-09-24/13-perf-final/`（`0-idle.csv`、60 s `sample-idle.txt`）。

空闲时间分散在几处常驻轮询上，没有单一热点。下面是 60 s `sample` 里各处的相对样本数（数字越大占时越多）：

- 2 s 一次的主轮询（`MenuBarModel.startPolling`，约 470），其中快照组装 `SessionStore.currentSnapshot` 约 450：133 个会话，加上对 1549 条回顾账本的 `RecapLedger.recap`（约 180）。
- Cursor 转录轮询，每 2 s 一次，覆盖约 124 个文件（`CursorTranscripts.discover`，约 300）。
- `claude agents --json` 刷新（`ClaudeAgentsSource.runCLI`，约 260）。这部分主要是在等管道；子进程的 CPU 不算在 App 头上。
- Codex rollout 候选扫描（约 110），`CursorComposerStore.refresh`（约 100），观测健康诊断（约 70），工具账本写盘（约 70）。

## 要做的

- 对每一处测量每分钟调用次数和单次耗时（`os_signpost` 或计数日志），先挑最大的两项。
- 候选做法：
  - Cursor 转录改用 FSEvents / kqueue 监听目录变化，或在没有 Cursor 活动时拉长轮询间隔。
  - 空闲时（没有 working / needsResponse 会话，也没有打开的界面）拉长主轮询间隔。
  - 快照未变化时不重算回顾。
  - 注意：不合并 recap ledger 的快照组装（已知约束，见 `SessionStore` 注释），不能以牺牲审批和提醒的时效为代价。

## 验收

- [x] 装机版，0 个 working 会话，10 min，启动后等待 ≥ 90 s：CPU 均值 < 2%。（1.50%，见 Comments）
- [ ] 5 个活跃会话 < 10%；2 h 内存不单调增长，保持 PERF-01 的结果。
- [ ] 审批卡片出现、完成提醒的延迟不变长（隔离 daemon 端到端 + 手动核对一次）。（未复测：审批走 hook，本 PR 没有改；Cursor 转录各测了一次，0.77 s 变为 working、0.10 s 变为 done，见 Comments）
- [x] `swift test` 与 Mac App 构建通过。

## Comments

- 2026-09-24（本 PR，隔离测量）：
  - 测法：同一份 origin/main（c617a5aa）和本分支的 Release App，各做一份 E2E 副本（bundle id `com.vibebuddy.e2e.*`，独立端口与根目录，不碰 `/Applications` 和 :9876）。每份读本机真实数据的 APFS 克隆：`~/.cursor/projects`（124 个转录）、`~/.codex/sessions`（819 个 rollout）、`~/.claude/projects`、Cursor 的 `state.vscdb`，以及账本（回顾账本 3.1 MB、工具账本 3.9 MB、生命周期日志等）；快照里 129 个会话。两份**同时启动、同时测**，抵消机器负载（测量时 load 在 400–1000 之间，其他会话在编译和跑模拟器）。启动后等 170 s，`ps -o time` 每 5 s 取累计 CPU，600 s；再各 `sample` 60 s，用 dSYM 符号化。脚本和原始数据在 `~/Projects/_shared-work/iOS-vibebuddy/perf-02-2026-09-24/`。
  - 定位（旧版 60 s `sample`，仅本 App 代码）：Cursor 转录轮询 163（每 2 s 列出并 stat 全部转录）、快照组装 215，其中回顾 97（每次快照都把一周约 1550 条账本全部建成条目，再只留 24 h 内最新 12 条）、Codex rollout 目录遍历 42、Cursor 数据库签名 `attributesOfItem`（连带读全部扩展属性）。
  - 修复：
    - Cursor 转录改成 FSEvents 唤醒：只有 `agent-transcripts` 下的写入会触发，一次处理后至少隔 2 s（与原来的固定节奏相同，忙时代价不增加），没有事件时 30 s 兜底一次；FSEvents 建不起来时退回原来的 2 s 轮询。项目目录里的 `worker.log`、终端输出等不会唤醒。
    - 回顾：先按 `Recap.compose` 的 24 h 窗口和排序筛选，只为最终保留的最多 12 条建条目；输出不变，快照组装和 `recapLedger.observe` 仍然每次都跑（没有合并）。
    - Cursor 数据库签名、Codex 日期目录检查改用 `stat` / `lstat`；漏看计数的周标签不再每 2 s 新建 `DateFormatter`。
  - 结果（同时段 A/B，600 s）：旧版 **2.13%**（p95 3.20%），新版 **1.71%**（p95 2.80%）。`sample` 中 Cursor 转录 163 → 14，回顾 97 → 31。剩下的主要是仪表盘窗口里每 2 s 刷新的相对时间标签（SwiftUI 布局，产品行为，不改）和 2 s 主轮询里分散的小项。
  - 时效：在新版副本里往克隆的 Cursor 转录追加一轮对话，快照 0.77 s 内变为 working，追加 `turn_ended` 后 0.10 s 内变为 done（原来固定 2 s 一次，最坏 2 s）。审批走 hook，不经过这些轮询。
  - 验证：全量 `swift test` 通过（1252 个 Swift Testing + 57 个 XCTest，1 个照旧跳过）；新增两个测试：转录写入唤醒尾随（两个定时器都设成 600 s，只有文件事件能送达）、周标签与 `yyyy-MM-dd` 格式化器在公历 / 佛历 / 和历下一致。Release App 构建通过。
  - 待做：合并后装机，按 PERF-01 的方法（启动后 ≥ 90 s，10 min，5 s 采样）测装机版空闲 CPU。
- 2026-09-24（#300 合并后装机验收）：
  - #300 经独立 Opus 评审两轮后合并（MERGE WITH FIXES → MERGE），合并提交为 43c52e0f。第一轮的两条应修：一是漏看周标签在农历、希伯来历下与旧格式化器不一致，改用 ICU 的 `Date.VerbatimFormatStyle`；二是唤醒测试原来用固定等待，改成等 seed 完成。两条均已修复。评审结论贴在 PR 评论里。
  - 11:00Z 从 main 43c52e0f 重建并替换 `/Applications`。替换前检查了 `vibebuddy-mcp status`、`git worktree list`、会话列表和投递台账，没有会话在共享 App 上做验收。12:08Z 另一个会话按 #301 又从 main 替换了一次。测量用的就是这一版，已确认二进制里含本 PR 的代码。
  - 测法同 PERF-01：`/Applications` 里的 App，启动 ≥ 90 s 后开始，`ps -o time` 每 5 s 采样，共 10 min；每分钟从快照数 working 会话。本会话在测量期间保持空闲。机器上其他会话一直在跑，所以用脚本等到连续 2 min 没有 working 会话才开始测；窗口内一旦出现 working 就作废重测（`perf-02-2026-09-24/installed-idle-try1…5`）。
  - 结果：第 5 次窗口干净（13:33–13:43Z，10 次检查都是 0 个 working，138 个会话），CPU 均值 **1.50%**，p95 2.6%，最大 15.4%。修复前 2.56%（b07b2dab，p95 4.2%），**达标**。此前 5 个窗口（`installed-43c52e0f`、try1–4）中途都出现了 1–2 个 working 会话，均值 1.73–4.02%，不计入。
  - 没有复测的三项（按推理豁免）：hook 事件路径上没有新增工作，只是变便宜了（每次快照组装回顾时少建条目）；Cursor 转录每次处理后仍至少间隔 2 s，与原来的固定节奏相同。所以 5 个活跃会话（6.2%）、2 h 内存（254 MB 持平）和审批延迟都不应变差。附带观察：活跃时的开销主要在每个 hook 事件都要做一次快照组装，并整份写回生命周期日志和 约 80 KB 的 `recent-directories.json`。这是负载路径的问题，要另开票才处理。
