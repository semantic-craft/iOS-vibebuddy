# vibebuddy — 实际进度审计 + 后续开发计划（2026-09-03）

> **已退役。** 当前进度与下一步以 [`status-and-plan-2026-09-04.md`](status-and-plan-2026-09-04.md) 为准。本文是 09-03 当天的过程存档，不要再当基线读。

**本文当时取代 `status-and-plan-2026-09-02.md`**，是 09-03 当天的"下一步"来源。判断依据是
2026-09-03 对每条分支、每个 worktree 逐一 checkout、跑测试、跑构建的结果，不是交接文件的自述。

基线：`main` = `origin/main` = `bb590b6`（PR #1、#2 已合）。今天在 main 上实跑：
VibeBuddyKit `swift test` 142/142、VibeBuddyMac 296/296、VibeBuddyApp iOS 模拟器构建 + 1 个测试、
VibeBuddyMacApp macOS 构建，全绿。仓库没有 CI（无 `.github/workflows`），也没有 Makefile。

**2026-09-03 收尾更新：** main 基线已推进到 `3b52cf1`（PR #6 已合并，`origin/main` 同步）。
第四节的阶段 A（MERGE）、阶段 B（小修）、阶段 E（Watch 续做的代码部分）已全部完成并入 main；
第六、七节取代第四节里这三段的内容——阶段 C（装机验收）和阶段 D（发布）仍然有效，但已经
收窄成第七节列出的、全部需要你本人在场的剩余步骤。

## 一、实际进度总表

| ID | 状态 | 分支 / 位置 | 验证证据 | 缺口 |
|---|---|---|---|---|
| P0 收口仓库 | done（09-02） | main | 见 09-02 文档第六节 | — |
| P1 装机 | **done**（09-03） | main | `docs/handoffs/handoff-2026-09-install.md`（gitignored）；`docs/qa-screenshots/2026-09-install/` 8 张 Mac 截图（**故意不入库**，含真实项目名）。Mac redeploy 成功、`:9876/health` ok、7 个 Settings 标签页可开、`/snapshot` 带 `childAgents` / observation / 五态字段；确认 `AccountUsage` **不在** `/snapshot` 里（W5 的前提成立）。iPhone 17 Pro Max / iOS 26.6.1 装机 + 配对 + Push Registered | (a) bug 单 `.scratch/acceptance-2026-09/issues/01-setup-tab-opens-scrolled-past-observation-health.md`（`ready-for-agent`）；(b) iPhone 三项目视检查未做：dashboard 五态颜色、Live Activity、Widget |
| P2 验收 | 未开始 | 主工作区 | — | 前置已满足；并吸收 P1 遗留 (b) |
| R3 ICP 备案 | **不适用（已决策）** | `docs/icp-app-filing-checklist.md`（main 检出里未跟踪） | 文件 09-03 已改写，头部标 "⛔ 不适用 — 只上美区不上国区"，含真实签名指纹 | 需要 commit 进 main |
| W1/W2/W3 Watch 01–03 | **代码完成，待合并** | `feat/watch-03`（6 提交 `257124f`→`94174b3`，26 文件 / +2796 行） | 今天在该 worktree 实跑：Kit 185/185、Mac 296/296、VibeBuddyAppTests 9/9（含 8 个 WatchRelayTests）、iOS 模拟器构建、watchOS 模拟器构建（Apple Watch Series 11）、Mac App 构建全绿；截图 `.scratch/qa-shots/watch-01`(14) / `watch-02`(8) / `watch-03`(5)；`merge-tree` 对 main 无冲突 | ticket 01/02/03 = `fixed-pending-merge`；给 `VibeBuddyApp/project.yml` 加了 `VibeBuddyWatch` target，新增 `tools/watch-qa-shots.sh`、`watch-relay-qa.sh`、`watch-live-qa.sh` |
| W5 Codex 周配额 | **代码完成，待合并** | `feat/watch-05-quota`（`2ee3ab9` + `d94fcca`，叠在 watch-03 之上） | Kit 185/185、Mac 309/309（含 "Provider quota projection" 套件，177 行新测试）、iOS + watchOS + Mac App 构建通过。`disabled → unavailable` 已实现（`AccountUsage.swift` `.disabled` → `unavailableReason .collectionDisabled`） | **设备验收未做**（无 `.scratch/qa-shots/watch-05`，ticket 05 仍 `ready-for-agent`）；Mac App 编译回归已修（D1）；必须排在 watch-03 之后合并 |
| R1 Mac 发布链路 | **代码完成，待合并**（超出原 spec） | `claude/r1-execution-7bf7ee`（`5fcf7e3`） | `tools/release-mac.sh`（311 行，preflight `needs_you()` 会停下、Sparkle 嵌套 helper 由内向外签名、公证 + staple、DMG、`sign_update`、appcast、`--skip-notarize` 干跑）、`tools/store-notary-credentials.sh`、`tools/vibebuddy-mac.entitlements`、`.gitleaks.toml`、`project.yml` 写入 SUFeedURL/SUPublicEDKey/MARKETING_VERSION 1.1、`docs/release-notes-1.1.md`。今天实跑：`bash -n` + shellcheck 干净、Kit 142 + Mac 296、分支 diff 上 gitleaks 0 命中、无冲突、与 `feat/release-ios` 文件零重叠。1.1 已 Developer-ID 签名 + 公证 Accepted + stapled + `spctl` 通过（profile `xw-notary`） | ticket `.scratch/mac-power-features/issues/07-sparkle-auto-update.md` = `ready-for-human`。**人工三步未做**：开 GitHub Pages（尚无 `gh-pages` 分支，否则 SUFeedURL 404）、发 v1.1 Release + appcast、真机走一次 Sparkle 应用内更新。文档缺陷见 D2 |
| R2 iOS TestFlight | **能做的都做完，待合并** | `feat/release-ios`（`75deedc`） | `tools/archive-ios.sh`（290 行；永不上传、只打印手动上传命令；API key 只按路径传；`--skip-export` 仅归档模式；校验 App Group `group.com.vibebuddy.app` 与 Widget 嵌入）+ `docs/app-store-paste-sheet.md`（244 行，含只上美区的理由）。`bash -n` + shellcheck 干净、xcodegen + iOS 模拟器构建通过、无冲突 | **archive 没跑过**：本机只有 "Apple Development" 与 "Developer ID Application"，没有 Apple Distribution；需要人工一次性用 Xcode 登录 Team `LQAVR62TK2` 或配 ASC API key。Watch target 未进 `archive-ios.sh`，见 P-B4。文档漂移见 D3/D4 |
| W4 / W6 / W7 / W8 | 未开始 | — | — | W4 依赖 W3 合并；W6 依赖 W5 合并且**要先修 ticket 06 的 spec drift**（原文写"本地 rate-limit cache"，实际是 `/usage` CLI）；W7 依赖 W3 + W6；W8 依赖 W4 + W7 + R2 的 TestFlight 通道 + 你在场 |

## 二、本次审计与清理记录（2026-09-03，全部本地，未 push）

- **W5 从悬空状态救回。** 它原本是 `.claude/worktrees/watch-05` 里一堆未提交改动，而分支 `feat/watch-05`
  只是指向 watch-03 的空指针。今天新建 `feat/watch-05-quota` 并提交为 `2ee3ab9`：`ProviderQuota` /
  `AccountUsageProvider` / `QuotaFreshness` 上提到 VibeBuddyKit；VibeBuddyMac 新增 `ProviderQuotaProjection`；
  `Snapshot.providerQuota` 可选字段；`SessionStore.setProviderQuota` / `currentSnapshot`；`MenuBarModel` didSet；
  `DashboardStore.lastProviderQuota`；Watch 配额视图改名。提交时**排除**了误删 Sparkle pin 的
  `VibeBuddyMac/Package.resolved`。
- **删除的 worktree / 分支**：worktree `watch-01`、`watch-02` 及分支 `feat/watch-01`、`feat/watch-02`
  （都是 watch-03 的严格祖先）；指针分支 `feat/watch-05`；`codex/agent-observability-v2` 和
  `grok/observability-04-codex-collaboration`（内容都已含在 `main-private-2026-09-02` 的旧历史里）。
- **保留不动**：`main-private-2026-09-02`（旧私有历史存档，**永不 merge**）、`prototype-2026-09-02`
  （`.scratch/watchos-companion-prototype` 唯一的 git 副本；main 检出的 `.scratch` 里另有磁盘副本）。
- **剩余 worktree**：`main`、`handover-cleanup-plan-f9104c`（本文所在，合并后删）、`r1-execution-7bf7ee`、
  `release-ios`、`watch-03`、`watch-05`。另外发现一个 `bar-size-list-navigation-ee3edf`（停在 `bb590b6`，
  零提交）——合并前确认没有会话在用，然后连分支一起删。
- origin 上只有 `main`。全程没有 push。

## 三、已知缺陷与文档漂移清单

- **D1（已修复）** W5 把 `AccountUsageProvider` 搬进 VibeBuddyKit 后，`VibeBuddyMacApp/Sources/UsageView.swift`
  漏了 `import VibeBuddyKit`，Mac App 编译失败。已在 `feat/watch-05-quota` 上以 `d94fcca` 修复并重跑 Mac App 构建 +
  Mac 309 测试。**遗留注意**：在该 worktree 跑 `swift test` 会把 `VibeBuddyMac/Package.resolved` 的 `originHash`
  改写掉，合并前 `git checkout -- VibeBuddyMac/Package.resolved`，不要把它带进 main。
- **D2** `docs/sparkle-setup.md:55-59` 说 Release 构建由 Xcode 在构建时签名；实际脚本用
  `CODE_SIGNING_ALLOWED=NO` 构建（`tools/release-mac.sh:146`）再由内向外手工签（`:157-182`）。改文档。
- **D3** `docs/app-store-listing.md:15` 的 promotional text 是 178 字符，超过 Apple 的 170 上限；
  `docs/app-store-paste-sheet.md:116` 已有改好的 147 字符版本。回填 listing.md。
- **D4** `docs/app-store-submission-checklist.md` 写 build = 1，但 `project.yml` 的
  `CURRENT_PROJECT_VERSION` 是 3；同文件 B4 说不需要 App Group，而 entitlements 里声明了
  `group.com.vibebuddy.app`。两处都改。
- **D5** Setup 标签页打开时已经滚过 Observation health（SwiftUI scroll anchoring）。ticket
  `.scratch/acceptance-2026-09/issues/01-...md`，`ready-for-agent`。**不适合 FIX 模板**——写不出有意义的失败测试，
  按目视修 + 截图验收。
- **D6** `VibeBuddyMacApp/Sources/RealtimeAudioIO.swift:117-118` 有 Swift 6 并发告警
  "captured var 'fed'"，是真实数据竞争风险，不是噪音。单独开票。

## 四、后续开发计划

原则不变：先把写好的代码合进 main 并装机验收，再开新功能。四条分支已经在等，合并是当前唯一的瓶颈。

### 阶段 A — MERGE（主工作区；串行；agent 可做，无需你在场）

一次一条，每条都是 rebase → 跑测试 → `merge --ff-only` → `tools/agent-worktree.sh --remove` →
`git branch -d`。**不 push。** 顺序不能换（4 叠在 1 上，2 和 3 只是排在后面减少 rebase 噪音）：

1. `feat/watch-03`（worktree `watch-03`）
2. `claude/r1-execution-7bf7ee`（worktree `r1-execution-7bf7ee`；该 worktree **缺 `.scratch` 软链**，
   改 ticket 07 要回主工作区改）
3. `feat/release-ios`（worktree `release-ios`）
4. `feat/watch-05-quota`（worktree `watch-05`）—— rebase 到新 main；rebase 前先丢掉被构建工具改写的 `Package.resolved`（见 D1）

每条合完的验收标准：VibeBuddyKit + VibeBuddyMac `swift test` 全绿，iOS / watchOS / macOS 三端构建通过，
对应 ticket 的 Status 从 `fixed-pending-merge` 改成 `done` 或写明保留的验收缺口。

然后在 main 上：commit `docs/icp-app-filing-checklist.md`（R3 决策留痕），最后合并本文档所在的
`claude/handover-cleanup-plan-f9104c`。**截图目录保持未跟踪**；如果哪天一定要入库，用 `VIBEBUDDY_DEMO=1` 重拍。

### 阶段 B — 小修（每项一个 `fix-<slug>` worktree，`tools/agent-worktree.sh` 建；可并行；agent 做）

- **FIX** Setup 标签页滚动位置（D5）——目视验收，不走 `tdd-bug-fix`。
- **DOC** D2 / D3 / D4 三处文档漂移，可以合成一个 worktree 一次改完。
- **R2 补 Watch**：watch-03 合并后，扩展 `tools/archive-ios.sh`（`WIDGET_IN_ARCHIVE` 附近 `:181-183`、
  `WIDGET_AUTH` 附近 `:259-264`）去校验嵌入的 Watch app。
- **可选** D6 的并发告警。

验收标准：相关 `swift test` 通过 + 受影响端构建通过；文档类只要求内容与代码一致，逐条对上第三节的编号。

### 阶段 C — 装机验收（**需要你本人在场**，App 在跑，手机已配对）

- **P2**：ticket 03 / 04 / 06 + 6 月遗留人工清单（`docs/roadmap-checklist-2026-06-06.md` 末节）
  + P1 欠的 iPhone 三项目视检查（dashboard 五态颜色、Live Activity、Widget）。提示词见
  `prompts-2026-09.md` 的 P2 段。
- **W5 设备验收**：真实 Codex 账号只读刷新 → Watch 显示周配额；关掉采集 → 显示 unavailable。
  截图进 `.scratch/qa-shots/watch-05/`，ticket 05 改 `done`。

验收标准：三张 observability ticket 与 ticket 05 改 `done` 或写明缺口；新发现的 bug 写进
`.scratch/acceptance-2026-09/issues/`。

### 阶段 D — 发布（**需要你本人**，卡在账号与证书上）

- **R1 发布**：开 GitHub Pages（建 `gh-pages` 分支，否则 SUFeedURL 404）→ 发 v1.1 GitHub Release +
  appcast → 真机走一次应用内 Sparkle 更新。三步都做完，ticket 07 才能改 `done`。前置：阶段 C 的 P2 完成。
- **R2 归档**：你先在 Xcode 里登录 Team `LQAVR62TK2` 拿到 Apple Distribution 身份（或配 ASC API key），
  然后 `tools/archive-ios.sh` 才能跑通。**上传 TestFlight 只在你明确说"上传"时做。**

### 阶段 E — Watch 续做（agent 独立写代码，可与 C、D 同时进行）

依赖图：`W6 ‖ W4 → W7 → W8`。worktree 名依次 `watch-06`、`watch-04`、`watch-07`、`watch-08`。

- **W6**（前置 W5 合并）：**动手前先修 ticket 06 的 spec drift**，把输入从"本地 rate-limit cache"
  改成已落地的 `/usage` CLI + `AccountUsage`，再实现。
- **W4**（前置 W3 合并）：一次性安全审批。
- **W7**（前置 W3 + W6）：后台 / 断连 / 通知可靠性。
- **W8**（前置 W4 + W7 + R2 的 TestFlight 通道，**需要你本人**和一块真 Apple Watch）：真机验收与发布。

### 必须你本人在场的清单

P2 的目视与听测、P1 欠的 iPhone 三项检查、W5 设备验收、R1 的 Pages / Release / 应用内更新实测、
R2 的签名身份与 TestFlight、W8 的真机验收。其余全部 agent 可独立完成。

## 五、工作流约束提醒

沿用 `prompts-2026-09.md` 的通用约束，不重复全文，只强调最容易破的五条：

1. **不 push、不改远端、不建 Release。** 集成只由主工作区的 MERGE 任务做。
2. **MERGE 只在主工作区，一次一条，`--ff-only`。** 不另立集成分支，不用 merge commit。
3. **分支任务先把自己放进 worktree**：`tools/agent-worktree.sh <name>`，它会把 `.scratch/`（ticket）和
   `.claude/skills` 软链回主工作区，所以改 ticket 状态直接落地。`r1-execution-7bf7ee` 是历史遗留，缺这个软链。
4. **不中断已装的 `/Applications/VibeBuddyMacApp.app` 和 `:9876`**；端到端验证用隔离端口 + 临时 `HOME`。
5. **装机验收（installed app + 真实 agent + 真机）是 `done` 的唯一标准。** 自动测试通过只写"自动测试通过"；
   模拟器通过 ≠ 真机通过。`*.xcodeproj` 是 xcodegen 生成物，不提交。

## 六、2026-09-03 集成结果（本节取代第四节的阶段 A/B/E）

main `3b52cf1` = `origin/main`。通过 PR #6（28 个提交）合并，PR #6 之前先合了 PR #4
（Grok parity，由另一个会话在 GitHub 上合并）和 PR #5（grokHome / turn-token 与 approval 顺序修复）。
本地 ff-merge 顺序：watch-03 → r1-execution → release-ios → watch-05-quota → grok parity
（rebase 到 `5737d41`）→ handover 计划 → ICP checklist → fix-mac-setup-scroll → watch-06 →
watch-04 → release-docs-and-watch-archive → 合并 `origin/main`（`e5a2fd2`）→ watch-07。

PR #6 头部 `6c7675f` 上的最终验收：VibeBuddyKit 218 个测试 / 26 个套件；VibeBuddyMac 459 / 44
（Approval 路由连跑两次都稳定）；VibeBuddyAppTests 21 个；macOS / iOS / watchOS 模拟器构建全绿；
`hooks/test_install_agent_hooks.py` 与 `hooks/tests/capture-terminal-parsing.sh` 通过。

**ticket 结果：**

- watch 01 / 02 / 03：`done`（模拟器验证；真机验收留给 W8）。
- watch 04：`merged-pending-device-acceptance`（单元测试 + 构建通过；配对模拟器上的中继被一个
  模拟器 IDS/iCloud 故障挡住——`identityservicesd` 报 `NSURLError -1002`）。
- watch 05：`merged-pending-device-acceptance`。
- watch 06：`merged-pending-device-acceptance`（真实 Claude 账号只读验证走的是一个隔离 daemon：
  周配额剩余 38%；Codex 被强制标记为不可用，不影响它）。
- watch 07：`merged-pending-device-acceptance`（配对模拟器上用真实 daemon（`:18766`）验证了 4 层
  连接中的 3 层；"手机关机" 与 "手机 App 状态陈旧" 两种情况在模拟器里区分不出来——`WCSession.isReachable`
  一直是 true；这两个标签要不要合并留给 W8 判断）。
- watch 08：`ready-for-agent`，但需要你本人。
- acceptance 01（Setup 标签页）与 02（RealtimeAudioIO 竞态）：`merged`。
- mac-power-features 07（Sparkle）：`ready-for-human`。

**关键技术发现：**

(a) `transferUserInfo` 在模拟器里从不投递到 Watch（iPhone 报告 `didFinish`，Watch 唤醒，但
`didReceiveUserInfo` 从不触发），所以中继继续用 `updateApplicationContext`（latest-wins 邮箱）
配合 `WatchStateInbox` 的顺序保护。
(b) Setup 标签页的 bug 不是滚动锚定问题：那个标签页根本缺了 `.formStyle(.grouped)`，所以压根没有
滚动视图。
(c) `claude -p /usage` 在整点重置时打印的文本不带分钟数，这曾经导致整个 Claude 读取失败。
(d) `archive-ios.sh --skip-export` 在 Xcode 自动签名下真跑通了，Watch app 内嵌在
`Watch/VibeBuddyWatch.app`——只有 `-exportArchive` / 上传还需要 Apple Distribution 身份。
(e) xcodegen 会自动内嵌 watchOS app 依赖，`project.yml` 不用改。
(f) `VibeBuddyAppTests` 从 `5737d41`（三次真实 demo 会话录制）之后就一直是红的——在 `2b544ef`
修复。

**今天完成的清理：** worktree `watch-03` / `watch-05` / `watch-04` / `watch-06` / `watch-07`、
`r1-execution`、`release-ios`、`handover-cleanup-plan`、`fix-mac-setup-scroll`、
`release-docs-and-watch-archive`、`prompt-audit-redundancies` 连同各自分支已删除；4 个空的
`claude/*` 分支已删除；7 个已结束的 CCD 会话已归档。剩余：`grok-build-status-monitoring-9445e6`
（正从 `3b52cf1` 部署）、`doctor-command-fcbb7a`（一个 flaky-test 修复会话，分支
`claude/amazing-golick-21a788`，尚无提交）、本次的编排 worktree。`main-private-2026-09-02` 与
`prototype-2026-09-02` 保留不动。仓库根目录有一个未跟踪的 `vibebuddy.json`——合并前手工复制的
Grok hook 配置，没有 gitignore——需要删除或加进 `.gitignore`。

**仍然打开的已知 flaky 测试：** "Claude CLI timeout and cancellation reap their child process"
（`AccountUsageTests`，固定时长的 sleep）；Approval 路由的 flake 已由 PR #5 的 `c3cde35` 修复。

## 七、剩余工作（全部需要你本人）

1. **R1 Mac 上线：** 建 `gh-pages` 分支并在 GitHub 开启 Pages（否则 `SUFeedURL` 404），发布 v1.1
   GitHub Release，附带 DMG 和 `tools/release-mac.sh` 生成的 appcast（具体步骤见
   `docs/sparkle-setup.md`），然后在一台真机上走一次应用内 Sparkle 更新。完成后 ticket
   `mac-power-features` 07 → `done`。
2. **R2 iOS/Watch TestFlight：** 用 Team `LQAVR62TK2` 在 Xcode 里登录（或配一个 ASC API key），
   这样 `tools/archive-ios.sh` 才能导出；只有你明确决定上传时才上传。`docs/app-store-paste-sheet.md`
   有商店文案（只上美区）。
3. **P2 装机验收（Mac + iPhone）：** observability ticket 03 / 04 / 06、6 月遗留人工清单、
   iPhone 三项目视检查、Setup 标签页目视检查（acceptance 01）。
4. **W5 / W6 设备验收，以及 W8 真 Apple Watch 对 W1–W7 的验收**，包括"手机关机"与"手机 App 状态
   陈旧"这两个标签要不要合并的决定，以及通知镜像的验收。
5. **可选：** 修掉剩下的 `AccountUsageTests` flake；做一遍 Watch 全局的 zh-Hans 检查（bundle 里
   确实带了 `zh-Hans.lproj`，按 ticket 07 所记，但要先在真机上验证）。
