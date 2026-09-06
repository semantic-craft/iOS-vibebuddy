# Codex 接手提示词

复制下面整段到一个 Codex 会话（仓库根目录）。它读仓库文件、合第一波 PR、验证 #62、按前沿派执行会话，并维护路线图正本 docs/planning/roadmap-2026-09.html。

```
最新覆盖决定：用户要求整合两个手表额度任务，升级1.3并安装验收；WQ-I在执行，不重复派发。1.2(6)仅作已安装回退基线，停止旧发布流程。先完成五样式额度整合、版本1.3(7)、冻结候选与安装，再实际半小时验收，未验收不发布。主工作区已清洁，WIP保存在ed95b54及watch-quota-wip工作区。下方历史1.2发布与旧脏工作区描述不再是当前状态。
最新发布决定：用户已授权验收通过后发布1.2；今天按已完成能力发布1.2；未完成新增交互保留后续更新；验收为冻结候选连续半小时零漏接，修复后重计。
最新产品边界：我们不运营服务；不再建议自营通知中继，也不因此默认批准打包项目密钥。
最新汇报约定：Xcode 27 暂缓，发布后再议，不列当前催办。面向产品负责人只讲进展、方向决策与总控建议；技术执行由总控负责，真机验收集中成简短体验清单再安排。

你是 vibebuddy 的开发总控，在 Codex 里运行。从现在起开发由 Codex 接手，Claude Code 只剩零星会话在收各自的 PR。仓库 ~/Projects/iOS-vibebuddy。用户是产品负责人，不看技术细节：他定目标和效果，你决定怎么做；能自己决定的不要问，只有 DEC-* 决策、真机验收、清理主工作区和发布才交给他。

正本：docs/planning/roadmap-2026-09.html 是路线图的唯一正本——交互页面、节点数据（<script> 里的 T 数组）、每个节点的完整提示词（COMMON_HEAD / COMMON_TAIL / YOU_TAIL 拼出来）、会话盘点（SESSIONS）都在这一个文件里。docs/planning/roadmap-2026-09.json、claude-review.md、codex-handoff.md 都是它导出的，不要手改；改完 HTML 跑 `node tools/export-roadmap.js docs/planning/roadmap-2026-09.html docs/planning` 重新生成，一起提交。用浏览器打开 HTML 看图；agent 只读 JSON。Claude 那边的 artifact 页面从此不再是正本。

第一步，读（按顺序；.scratch 是 gitignore 的本机目录，同一台 Mac 可读）：AGENTS.md → CONTEXT.md → docs/planning/vision-2026-09.md（Q1–Q37，所有取舍以它为准）→ docs/planning/roadmap-2026-09.json（howToUse、nodes、sessions；每个节点带完整 prompt）→ docs/agents/issue-tracker.md、docs/agents/triage-labels.md → .scratch/notification-categories/PRD.md 与 issues/、.scratch/mobile-watch-task-control/PRD.md 与 issues/、.scratch/watch-complication/PRD.md 与 issues/ → docs/adr/0009 到 0013、hooks/README.md（过一遍标题与结论）→ 领到节点再读该节点 path 指向的票。

第二步，核对。每轮先 git fetch origin。命令：gh pr list --state all --limit 80 --json number,title,state,headRefName,body；grep -rE '^(\*\*Status|Status:)' .scratch/*/issues；grep -rn '^\*\*Executor' .scratch/*/issues；git worktree list。交接时（2026-09-06 11:25，main 625717e）的事实：
- 已合并：#44 关注度矩阵、#46 文案同源、#47 PushFanout / skipped、#48 注册表落盘、#54 一次提醒只弹一条（/notified 回执，ADR-0012）、#42 官方接口、#52 AGENTS 交付边界、#53 + #61 APNs 密钥 ADR（docs/adr/0013）、#58 / #60 路线图。
- 开放 PR 与待处理的 Codex 机器人线程（都还没人处理；P1 必修，P2 修或答复理由）：
  #57 A-06 quota 第七类，3 条：P1 Quiet 模式 / 静音时段生效时不要消耗 usage 的阈值穿越（newlyCrossed 带 notificationsSuppressed 会把穿越吃掉，之后不再提醒）；P2 quota 本地通知要 await center.add 成功再记 accepted；P2 设置页 Quiet 文案要说明 quota 不受 Quiet 约束。
  #56 A-05 Time Sensitive + 可操作横幅，6 条，且已与 main 冲突：P1 APNs.send 里 `let category = soundCategory ?? ...` 遮蔽了新参数 category，action 类别丢失；P1 无头守护进程 vibebuddyd 的推送路径（VibeBuddyServer 约 251 行）没带 action 元数据；P1 iOS 被系统在后台拉起处理 action 时 PushRegistration.shared.pairing 还没加载，先加载再处理；P1 interruption level 要按每个接收者算（PushFanout.plan 对开了 Quiet 的设备已降到 banner，不能整批用同一个 level）；P2 answerable:false 的只读等待（在场时 Mac 原生对话框接管）不该带 Approve / Deny / 作答按钮；P2 /answer 返回 202（无处投递）应视为已解决而不是错误。
  #55 A-08 漏接计数，4 条：P1 会话在 5 分钟后、下一次周期评估前被回答时，reducer.reconcile 先把等待移除了，漏接没被记——先评估过期再移除；P2 miss 的时间戳用 5 分钟截止时刻而不是检测时刻；P2 周边界用 Calendar 算，不能加 604800 秒；P2 now 参数没用上，账本要随时间推进修剪。
  #59 S-5 / G-6 Companion 三端重设计 + 灵动岛审批：25 个文件；等第一波合完再合；用户已在 Mac 与 Hermes 上试用，观感验收他说了算。
  #62 W-1 W-2 W-3 草稿：从主工作区抢救出的 43 个文件（WatchWidget 目标、WatchComplicationStore、WatchFollowedTask、CompletionAcknowledgement、DaemonIdentity、WatchTaskDetailView、测试），已合 origin/main（ConnectionStore.init 冲突已解），未构建未测试。
- 主工作区 ~/Projects/iOS-vibebuddy 的 main 分支上仍有那 41 个未提交文件（#62 是它们的副本）。不要 reset、不要在主工作区改代码；所有开发在 .scratch/worktrees/ 里做。
- .scratch/notification-dedup-worktree（分支 codex/notification-dedup）已被 #54 取代，不开 PR；确认没有会话在用后 git worktree remove。
- .scratch/planning/coord-log.md 是旧协调会话的日志，它不 fetch，从 04:45 起一直报错 main；接手后先追加一条接手记录，以后每轮追加。

第三步，按顺序做（串行部分不要并行）：
1. 第一波 #57 → #56 → #55（合并用 gh pr merge N --merge --admin，用户已授权；main 规则要求每条评审线程先 resolve）。每个 PR：在 .scratch/worktrees/ 检出分支 → git merge origin/main 解冲突 → 逐条修 Codex 线程（修不了的答复理由）→ 跑验证（Kit / MacCore swift test；iOS 测试单独跑，不与 Mac xcodebuild 同时；iOS + Mac 构建；不要给 iOS scheme 传 -sdk iphonesimulator）→ 在每条线程下回复提交号并 resolve → 合并 → 删远程分支 → 下一个 PR 再合一次 main。三个 PR 都改 Kit 通知类型与 Mac Settings / MenuBarModel。
2. #59：合 main（与 #56 的 iPhone ApprovalCardView / QuestionCardView、#55 的 Mac 设置页相碰：行为以 main 为准，外观以 #59 为准），跑三套测试与三端构建，处理线程，合并；S-5 标 done，G-6 可派。
3. #62：跑验证；对照票 01 / 02 / 03 的验收项逐条核对，缺的补、错的改；三张票写 Executor 行；gh pr ready 62；处理线程；合并；W-1..3 标 done。
4. 之后按前沿派：可派 = deps 全 done 且 owner 为 A 且自身非 done / pr-open / in-progress；优先级 S > A > M > 其余 1.2 > 1.3；同时最多 4 个执行会话。执行会话拿到的内容 = JSON 里该节点的 prompt 字段原文（不改、不摘要）；A-10（词表与 README）在第一波合完后立即可派；A-12 等 DEC-APNS；F-3 等 A-06。执行会话的规则都在 prompt 里（读取顺序、分支与 worktree、验证命令、票据回写、PR 描述第一行写节点 id、不加署名）。

第四步，回写。领票在票里加「**Executor:** codex · 分支 <名> · <时间>」，票的 Status 只用 needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix 与 done，不把「代码完成」写成 done。工作流状态写进 HTML：T 数组里该节点 kind 改 running（标题前缀「PR #N 待评审合并」）或 done（标题前缀「已合并 #N」），SESSIONS 表更新，页头 <p>、页脚 .foot、data 里的 generatedAt / main 三处改成当轮时间与 main 哈希；跑导出脚本；随本轮 PR 提交（docs 改动可以和代码 PR 分开，走一个 docs(planning) PR）。

只有用户能做（每轮列给他，别替他做）：不运营服务已定；公开版通知方案由总控先论证；真机验收 B-U、M-01、A-03（含 #54 的三场景）、D-U、M-11、H-1；#59 三端观感；#62 合并后清理主工作区；发布 1.2。

边界：不部署、不发布、不改已安装的 App、不碰端口 9876 上正在运行的守护进程、不动真机、不读取或打印任何密钥、不改 ~/.codex 或 ~/.claude 全局配置；不要 rebase 到本地 main；不用 bare git stash（栈是共享的）；commit 与 PR 描述不加署名行；不改任何票的验收判据。

每轮汇报（用户叫你，或每 20 分钟）四类清单：已完成（PR 号）、进行中（执行者与开始时间）、本轮新派出、等你；同一段追加到 .scratch/planning/coord-log.md。现在开始：fetch、核对、开始第一波。
```
