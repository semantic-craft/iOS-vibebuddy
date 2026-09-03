# vibebuddy — 后续任务提示词包（2026-09）

> **任务集已全部完成或改写。** 当前的任务与提示词见 [`plan-remaining-work.html`](plan-remaining-work.html)。下面的「通用约束」一节仍然有效并被引用，所以本文保留、不要删。

配套 `status-and-plan-2026-09-03.md`（它取代了 09-02 版）。每个任务一段提示词，Claude Code / Codex / Grok 通用。
**状态标记（2026-09-03 核对）：** ✅ 已完成 · 🔀 代码完成待合并 · ⛔ 不适用 · ⬜ 未开始。
**给 agent 的用法：** 你收到的一句话是 `按 docs/planning/prompts-2026-09.md 只执行 <ID>`，
就先读「通用约束」，再只做那个 ID 的任务，其它任务一个字都不要碰。

## 会话编排：哪些并行，哪些串行

```
✅ P0 收口仓库 → ✅ P1 装机 → 【当前瓶颈】MERGE ×4，串行，主工作区

MERGE 顺序（不能换；4 叠在 1 上）：
  1 feat/watch-03  →  2 claude/r1-execution-7bf7ee  →  3 feat/release-ios  →  4 feat/watch-05-quota

合并后：
 ├─ Lane A  你在场（主工作区，一次只开一个会话）
 │    P2 验收 03/04/06 + 6 月清单 + P1 欠的 iPhone 三项目视 → 发现 bug → FIX ×N（可并行）
 │    W5 设备验收（真实 Codex 账号 → Watch 周配额）
 │
 ├─ Lane B  agent 独立写代码（不需要你；每个任务一个 worktree）
 │    FIX / DOC 小修（阶段 B）；W6 ‖ W4 → W7 → W8（W8 需要真 Watch + Lane C）
 │
 └─ Lane C  账号 / 密钥（需要你本人）
      R1 发布：GitHub Pages + v1.1 Release + appcast + 应用内更新实测
      R2 归档：Apple Distribution 身份 / ASC API key，然后 TestFlight
      v1.1 正式发布 = R1 发布完成 且 P2 完成
```

- **可以同时开几个会话：** 可以。硬限制只有三条：每个代码任务一个 worktree + 分支；Lane A 一次只有一个会话碰已安装的
  App、9876 端口和手机；MERGE 串行。实际并发建议 3 个左右（A、B、C 各一个），再多 Swift 编译会互相拖慢。
- **为什么 Watch 可以现在就开：** W1 到 W7 是纯代码，不需要设备也不需要你；你在 Lane A / C 排队等账号、
  等真机的时候，B 一直在跑。合并时 rebase 到 main 即可。
- **每个任务之间的文件所有权：** W3 拥有 Watch 状态里的 session / alert 字段，W5 拥有 quota 字段；
  R1 只碰 `tools/`、`dist/`、`VibeBuddyMacApp/project.yml`，R2 只碰 `VibeBuddyApp/project.yml`、`tools/archive-ios.sh`、`docs/`。

## 启动方式（最少复制粘贴）

**Claude Code 桌面版（默认）：** 在项目文件夹 `~/Projects/iOS-vibebuddy` 上开一个新会话，粘一行，其它什么都不用做：

```
按 docs/planning/prompts-2026-09.md 只执行 P1
```

```
按 docs/planning/prompts-2026-09.md 只执行 W1
```

```
按 docs/planning/prompts-2026-09.md 只执行 R1
```

分支任务（W*、R*、FIX）由 agent 自己建 worktree 并切进去（见通用约束第 2 条）；主工作区任务（P1、P2、MERGE）留在项目文件夹。
几个会话可以同时开，错开几秒即可。

**终端 / Codex / Grok（可选）：** 先建 worktree 再起会话：

```bash
cd "$(tools/agent-worktree.sh watch-01)" && codex "按 docs/planning/prompts-2026-09.md 只执行 W1"
```

```bash
~/.grok/bin/grok --cwd "$(tools/agent-worktree.sh watch-01)" "按 docs/planning/prompts-2026-09.md 只执行 W1"
```

worktree 名字对照：`watch-04` / `watch-06` / `watch-07` / `watch-08`、`fix-<slug>`。
已存在的 worktree 与分支：`watch-03`→`feat/watch-03`、`watch-05`→**`feat/watch-05-quota`**、
`r1-execution-7bf7ee`→`claude/r1-execution-7bf7ee`（**缺 `.scratch` 软链**，改 ticket 要回主工作区）、
`release-ios`→`feat/release-ios`。`watch-01` / `watch-02` 与 `feat/watch-01` / `feat/watch-02` 已在 09-03 删除。
`tools/agent-worktree.sh` 会把 `.scratch/`（ticket）和 `.claude/skills` 软链到主工作区，所以 ticket 状态改动直接落地，不用合并。

## 通用约束（每个任务都先读）

1. 只做被点名的那个任务 ID；不碰其它任务的文件；只改自己 ticket 的 Status。
2. **分支任务先把自己放进 worktree：** 运行 `tools/agent-worktree.sh <name>`（name 见任务标题），它会在 `.claude/worktrees/<name>` 建分支 `feat/<name>` 并打印路径；
   Claude Code 随后用 EnterWorktree（`path` = 打印出的路径）切换进去，Codex / Grok 则 `cd` 进去。之后所有读写、构建、测试、提交都在那里。
   主工作区任务（P1、P2、MERGE、R3）不建 worktree。`.scratch/` 和 `.claude/skills` 是软链，直接改即可。
3. 不 push、不 merge main、不建 Release、不改远端。集成由主工作区的 MERGE 任务做。
4. 不中断已安装的 `/Applications/VibeBuddyMacApp.app` 和 `:9876`。端到端验证用隔离端口 +
   临时 `HOME` + 临时日志路径（例：`VIBEBUDDY_PORT=18765 VIBEBUDDY_TOKEN=e2e ./.build/debug/vibebuddyd`）。
5. `*.xcodeproj` 是生成物：先在 `VibeBuddyMacApp/` 或 `VibeBuddyApp/` 跑 `xcodegen generate`，不要提交。
6. 验证入口：
   - `cd VibeBuddyMac && swift test`；`cd VibeBuddyKit && swift test`
   - Mac App：`xcodebuild -project VibeBuddyMacApp/VibeBuddyMacApp.xcodeproj -scheme VibeBuddyMacApp -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
   - iOS：`xcodebuild -project VibeBuddyApp/VibeBuddyApp.xcodeproj -scheme VibeBuddyApp -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
7. 少量聚焦测试保护归约主路径，真实端到端才算验收。报告分层：自动测试通过 ≠ 模拟器通过 ≠ 真实 agent 通过 ≠ 真机通过，不要混成一个"完成"。
8. 信号不足显示 `unknown` / `degraded`；通知只写 `attempted` / `scheduled` / `accepted` / `failed`。
9. 最简实现；不留兼容层、fallback、迁移层；不做投机抽象。
10. 完成时：Conventional Commits 提交到分支；回写 ticket 的 checklist / Status / Implementation notes；
    回复末尾给「集成清单」：分支名、提交列表、测试与构建结果、未验证项。

---

## ✅ P0 — 收口仓库（已完成 2026-09-02；保留为记录，不要重跑）

按 `status-and-plan-2026-09-02.md` 阶段 0 顺序执行：
1. `git stash push -u` 做安全网 → `git merge --ff-only grok/observability-04-codex-collaboration` →
   从 `stash@{0}^3` 取回本地未跟踪资料（含 `docs/planning/status-and-plan-2026-09-02.md`、`prompts-2026-09.md`、
   `tools/agent-worktree.sh`）→ 重新加 `roadmap.md` 顶部指向。
2. 回填 ticket：`.scratch/agent-observability-v2/issues` 01 / 02 / 05 / 07 / 08 和 `.scratch/codex-micro-status-parity` 01
   的 Status 改 `done`，勾选已验证项；03 / 06 / 04 保持 `ready-for-human`，把 P2 的验收项写入 checklist；
   `GROK_BUILD_HANDOFF.html` 顶部加一行"2026-09-02 已集成到 main，本页的分支冻结规则失效"。
3. 公开 / 私有历史：`git branch main-private-2026-09-02 main` → `git rebase --onto origin/main d295a9c main` →
   解决 `hooks/README.md`、`hooks/codex-notify*.sh`、`.gitignore` 冲突（以 main 内容为准，保留公开版的 `.scratch/`、`.claude/` 忽略）→
   `git rm -r --cached .scratch` 提交 `chore: stop tracking .scratch on the public history`。结束时 `git status -sb` 应只显示 ahead，不显示 behind。不 push。
4. `CONTEXT.md` 增加：ObservationSource、ChildAgent、AccountUsage、TaskPresentation、LifecycleJournal、NotificationDelivery。
5. 跑 Mac + Kit `swift test`，两端 build；报告。

---

## ✅ P1 — 装机（已完成 2026-09-03；保留为记录）

证据：`docs/handoffs/handoff-2026-09-install.md`、`docs/qa-screenshots/2026-09-install/`（8 张，故意不入库）。
**遗留给 P2：** iPhone 三项目视检查（dashboard 五态颜色、Live Activity、Widget）未做；
bug 单 `.scratch/acceptance-2026-09/issues/01-setup-tab-opens-scrolled-past-observation-health.md`。

前置：P0 完成。
1. `tools/redeploy-mac.sh`：Release 构建、稳定签名、替换 `/Applications`、等 `:9876/health`。Keychain 弹窗点 Always Allow 一次。
2. 检查 Settings 每个标签页（General / Glance / Notifications / Setup / Observation / Usage / Delivery / Timeline）都能打开且无错误；
   `curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/vibebuddy/token)" 127.0.0.1:9876/snapshot`
   看到 `childAgents`、observation 元数据、五态字段。
3. iPhone：插线，`cd VibeBuddyApp && xcodegen generate`，用 Xcode 或 `xcodebuild -destination 'id=<设备 UDID>'` 装到手机；扫码配对；
   dashboard 五态颜色、Live Activity、Widget 各看一眼。
4. 截图放 `docs/qa-screenshots/2026-09-install/`。小问题现场修（分支 `fix/<slug>`，走 FIX 流程），大问题写成
   `.scratch/acceptance-2026-09/issues/NN-<slug>.md`（模板：What / Repro / Expected / Status: ready-for-agent）。
5. 交付：`docs/handoffs/handoff-2026-09-install.md`，不超过 40 行。

---

## ⬜ P2 — 验收 03 / 04 / 06 + 6 月遗留清单（Lane A；主工作区；你在场）

**并做 P1 欠的 iPhone 三项目视检查：dashboard 五态颜色、Live Activity、Widget。**

前置：P1 完成（已满足），App 在跑，手机已配对。逐项做，每项给证据（截图 / snapshot 片段 / Delivery log 行）：
- **03 Claude 子代理**：在临时项目里 `claude -p "用 Agent 工具并发跑两个 Explore..."`；Mac / iOS 会话行出现子代理计数与名称；一个完成一个仍在跑；
  `SessionEnd` 后行消失；中途 `kill` 并重启 daemon，恢复后没有幽灵子代理。决定是否补 `TeammateIdle` hook。
- **04 Codex collaboration**：Codex Desktop 发一个会 spawn 两个子 agent 的任务；覆盖 wait-any、interrupt 其中一个、父 turn 先结束、daemon 中途启动；
  对照 ticket 04 的归约表，信号不足的地方必须是 `unknown` / degraded。
- **06 通知投递**：手机在线时触发一次 approval，Delivery log 出现 APNs `accepted`；本地通知 `scheduled` 横幅弹出；
  关掉通知权限再触发，记录 `failed / permissionDenied`；同一失败原因短时间只提示一次。
- **6 月清单**：always-allow 后下次自动批准；allow-session 本会话不再问；双终端前台抑制（`ForegroundTerminal`）；
  跳转到 Warp / kitty；Setup 标签页目视并补 zh-Hans 串；iOS 语音听测补 OpenAI / Qwen 路径；Live Activity 真机后台推送。
- 交付：03 / 04 / 06 三张 ticket 改 `done` 或写明缺口；`docs/roadmap-checklist-2026-06-06.md` 末节逐条更新；
  bug 写入 `.scratch/acceptance-2026-09/issues/`；`docs/handoffs/handoff-2026-09-acceptance.md`。

---

## 🔀 W1 — Watch 01：可安装的 Watch demo（已完成，在 `feat/watch-03` 上待合并）

读：`.scratch/watchos-companion/PRD.md`、`issues/01-installable-watch-demo-experience.md`、
`.scratch/watchos-companion-prototype/DECISION.md`（只取结构，不搬原型代码）、`docs/adr/0007-ios-pixel-cat-mac-robot.md`。
做：`VibeBuddyApp/project.yml` 增加 watchOS target，嵌入现有 iOS app；按 DECISION 三态：A 默认首页（三桶计数 + 像素猫 + 次要配额）、
B 紧急接管（最高优先级 `needsResponse` 时替换首页；本票只读）、C 配额详情页。demo 数据覆盖 needsResponse / working / done / 空态 /
配额 stale 与 unavailable；`VIBEBUDDY_DEMO=1` 生效。**若 VibeBuddyKit 不能为 watchOS 编译，只把 Watch 需要的 wire 词汇拆成最小模块，不做整体边界重构。**
验证：Watch Simulator 装机运行；每个 demo 场景一张截图到 `.scratch/qa-shots/watch-01/`；iOS + watchOS xcodebuild、Kit `swift test` 通过。

## 🔀 W2 — Watch 02：iPhone → Watch 最新状态中继（已完成，在 `feat/watch-03` 上待合并）

读：PRD「Solution」里的投影一段、`issues/02-iphone-watch-latest-state-relay.md`、`VibeBuddyApp/Sources/DashboardStore.swift`。
做：先冻结 Watch 状态模型 `WatchState`（五态计数、最高优先级会话摘要、配额占位、`freshness` 元数据）；纯函数投影
`(Snapshot, 连接状态, 时钟) → WatchState`，放在 iOS app 里，单元测试穷举；WatchConnectivity 用 `applicationContext` 传最新值；
Watch 永远拿不到 Mac token，也不直连 daemon；断连时 Watch 显示数据年龄而不是当作实时。
验证：投影测试；iPhone Simulator + Watch Simulator 配对，改 Mac 快照后 Watch 更新；断开后显示 stale。

## 🔀 W3 — Watch 03：实时状态 + 只读告警（已完成，`feat/watch-03` / worktree `watch-03`，待合并第 1 位）

读：`issues/03-live-session-status-and-read-only-alerts.md`。你拥有 `WatchState` 的 session / alert 字段，不碰 quota 字段。
做：首页实时计数；最高优先级 `needsResponse` 触发 B 接管，显示只读详情；进入 `needsResponse` 时 Watch 本地通知，
与 iPhone 转发的通知不重复；恢复后接管自动退出。
验证：真实 daemon 快照驱动的模拟器配对；断连 / 恢复；通知不重复。

## 🔀 W5 — Watch 05：Codex 周配额端到端（代码完成，**`feat/watch-05-quota`** / worktree `watch-05`，待合并第 4 位）

叠在 `feat/watch-03` 之上，必须最后合。分支 = `2ee3ab9`（W5 本体）+ `d94fcca`（补 `UsageView.swift` 的
`import VibeBuddyKit`，修 Mac App 编译回归）。合并前 `git checkout -- VibeBuddyMac/Package.resolved` 丢掉构建工具的
`originHash` 改写。**设备验收未做**，ticket 05 仍 `ready-for-agent`。

读：`issues/05-codex-weekly-quota-end-to-end.md`、`VibeBuddyMac/Sources/VibeBuddyMacCore/AccountUsage.swift`、`CodexAppServerUsageProvider.swift`。
你拥有 `WatchState` 的 quota 字段。**输入是分支上已验收的 `AccountUsage`，不再另写采集。**
做：若 `AccountUsage` 还没进 wire 快照，最小化地加进 `Snapshot`；iPhone 投影到 Watch quota 模型（剩余百分比、重置时间、更新时间、stale / unavailable）；
C 页展示。验证：真实 Codex 账号只读刷新 → Watch Simulator 显示；禁用采集后显示 unavailable。

## ⬜ W4 — Watch 04：安全的一次性审批（Lane B；worktree `watch-04`；前置 W3 已合并；可与 W6 并行）

读：`issues/04-safe-one-shot-watch-approval.md`、`docs/adr/0010-always-allow-in-vibebuddy-store.md`、iOS `ApprovalDecision` 用法。
做：只有详情完整（工具、命令 / 路径、项目）时才显示 Approve / Deny；决定经 iPhone 转发到 Mac `/decision`，带请求 id 幂等；
结果回显；question 类型本票仍只读；不提供 always-allow。验证：模拟器配对下一次审批往返；重复点击不重复提交；断连时按钮禁用并说明。

## ⬜ W6 — Watch 06：Claude 周配额端到端（Lane B；worktree `watch-06`；前置 W5 已合并；可与 W4 并行）

读：`issues/06-claude-weekly-quota-end-to-end.md`、`ClaudeCLIUsageProvider.swift`。
**先修 spec drift：** ticket 原文写的"Claude Code 本地 rate-limit cache"已被 08 的官方 `/usage` CLI + `AccountUsage` 取代，
先把 ticket 改成以此为输入，再实现。做：复用 W5 的 quota 模型加 Claude 提供方；两者独立启用 / 失败隔离；C 页并列显示。
验证：真实 Claude 账号只读刷新 → Watch 显示；单方失败不影响另一方。

## ⬜ W7 — Watch 07：后台、断连与通知可靠性（Lane B；worktree `watch-07`；前置 W3 + W6 已合并）

读：`issues/07-background-disconnection-and-notification-reliability.md`。
做：iPhone 后台 / 锁屏时的中继（`transferUserInfo` 队列 + 去重）；Watch 端 stale 阈值与显示；通知在 iPhone / Watch 间不重复、不丢；
Mac 断连 → iPhone 断连 → Watch 三层状态各自可辨。验证：模拟器下依次断开每一层并恢复，记录每层的 Watch 显示。

## ⬜ W8 — Watch 08：真机验收与发布（Lane B 收尾；worktree `watch-08`；前置 W4 + W7 已合并，R2 的 TestFlight 链路可用；**你在场 + 真 Apple Watch**）

读：`issues/08-release-and-real-device-acceptance.md`。做：TestFlight 构建含 Watch app；真实 Apple Watch 上过一遍 W1–W7 的验收项；
截图与缺口写回 ticket；PRD Status 改 `done` 或列出剩余项。自动测试和模拟器不能替代本票。

---

## 🔀 R1 — Mac 发布链路（代码完成，`claude/r1-execution-7bf7ee` / worktree `r1-execution-7bf7ee`，待合并第 2 位）

已超出下面的 spec：1.1 已 Developer-ID 签名 + 公证 Accepted + stapled + `spctl` 通过（profile `xw-notary`）。
ticket `.scratch/mac-power-features/issues/07-sparkle-auto-update.md` = `ready-for-human`。
**剩余三步需要你本人：** 开 GitHub Pages（尚无 `gh-pages` 分支，否则 SUFeedURL 404）、发 v1.1 Release + appcast、
真机走一次应用内 Sparkle 更新。另需修文档：`docs/sparkle-setup.md:55-59` 说 Xcode 构建时签名，
实际是 `tools/release-mac.sh:146` 用 `CODE_SIGNING_ALLOWED=NO` 构建、`:157-182` 由内向外手工签。

读：`docs/sparkle-setup.md`、`tools/redeploy-mac.sh`、`VibeBuddyMacApp/project.yml`、`docs/app-store-listing.md`（发布说明素材）。
做：`tools/release-mac.sh`：Release 构建 → Developer ID 签名（identity 由参数指定）→ `xcrun notarytool submit --keychain-profile vibebuddy-notary --wait`
→ `stapler staple` → `hdiutil` 打 DMG → Sparkle `sign_update` → 生成 appcast 条目。appcast 托管定一种（推荐 GitHub Pages 的 `gh-pages` 分支），
`project.yml` 填 `SUFeedURL` / `SUPublicEDKey`，版本号 1.1。起草 `docs/release-notes-1.1.md`（observability + Codex hooks）。
**需要用户做、脚本到该处要停下并明确提示的：** Xcode 创建 Developer ID Application 证书；`xcrun notarytool store-credentials vibebuddy-notary`
（用户自己输入 API key，你不接触密钥）；Sparkle `generate_keys`（私钥进 Keychain）。
验证：能 dry-run 到 DMG；证书就绪则 `spctl --assess -vv` 通过。**不发布 v1.1、不建 GitHub Release**，正式发布等 P2 完成后由 MERGE 会话做。

## 🔀 R2 — iOS TestFlight（能做的都做完，`feat/release-ios` / worktree `release-ios`，待合并第 3 位）

已交付 `tools/archive-ios.sh`（290 行）+ `docs/app-store-paste-sheet.md`（244 行）。
**archive 没跑过**：本机只有 Apple Development 与 Developer ID Application，缺 Apple Distribution；
需要你在 Xcode 登录 Team `LQAVR62TK2` 或配 ASC API key。**上传 TestFlight 只在你明确说「上传」时做。**
合并后待办：给 `archive-ios.sh` 加 Watch target 校验（`:181-183` `WIDGET_IN_ARCHIVE`、`:259-264` `WIDGET_AUTH` 附近）；
回填 `docs/app-store-listing.md:15`（178 字符 promo 超 170 上限，改用 paste-sheet:116 的 147 字符版）；
修 `docs/app-store-submission-checklist.md`（build 写 1 但 `CURRENT_PROJECT_VERSION` 是 3；B4 说不需要 App Group，
而 entitlements 声明了 `group.com.vibebuddy.app`）。

读：`docs/app-store-submission-checklist.md`、`docs/app-store-listing.md`、`docs/privacy-policy.md`、`VibeBuddyApp/project.yml`。
做：核对 Release 配置（`aps-environment` production、version 1.0 / build 1、`ITSAppUsesNonExemptEncryption`、图标、Widget bundle id、
Watch target 若已合并则一并带上）；`tools/archive-ios.sh`：`xcodebuild archive` + `-exportArchive`（method app-store-connect，
`-allowProvisioningUpdates`，API key 路径由参数传入，你不读取密钥内容）；把用户要在网页上粘贴的所有文本按 App Store Connect 字段顺序整理成
`docs/app-store-paste-sheet.md`（名称、副标题、描述、关键词、Support URL、隐私政策 URL、隐私标签逐项、reviewer notes、演示账号说明）。
前置：Apple Developer Program 已付费。没有就做到 archive 成功为止，并把剩余人工步骤列成最短清单。
验证：archive 成功；export 成功。**不上传到 App Store Connect，除非用户在会话里明确说上传。**

## ⛔ R3 — 国区 ICP 备案（不适用，2026-09-03 决策：只上美区，不上国区）

`docs/icp-app-filing-checklist.md` 头部已标「⛔ 不适用」，待在 main 上提交留痕。下面的原文仅存档。

只有用户决定上国区才做。读 `docs/icp-app-filing-checklist.md`，按其顺序把 agent 能做的核对与文案项做完（名称候选、包名、公钥 / SHA-1 提取命令、
后台域名填写说明），实名、付费、人脸留给用户，每步说明需要什么。不改代码。

---

## FIX — 缺陷修复模板（worktree `fix-<slug>`）

参数：ticket 路径 `.scratch/acceptance-2026-09/issues/NN-<slug>.md`。
做：先写一个能复现的失败测试（`tdd-bug-fix`），再修；只改与该缺陷相关的文件；跑相关 `swift test` 与受影响端的 build；
ticket Status 改 `fixed-pending-merge`，写清根因。交付集成清单。

## MERGE — 集成模板（主工作区；一次一个分支）

**2026-09-03 待合并队列，顺序不能换：** 1 `feat/watch-03`（`watch-03`）→ 2 `claude/r1-execution-7bf7ee`
（`r1-execution-7bf7ee`）→ 3 `feat/release-ios`（`release-ios`）→ 4 `feat/watch-05-quota`（`watch-05`，
先处理未提交改动）。全部合完后在 main 上提交 `docs/icp-app-filing-checklist.md`，最后合并规划分支。
截图目录（`docs/qa-screenshots/`、`.scratch/qa-shots/`）保持未跟踪。

参数：分支名（如 `feat/watch-03`），worktree 名（如 `watch-03`）。
做：`git status -sb` 确认主工作区干净；在该 worktree 里 `git rebase main`，解决冲突；跑 Mac + Kit `swift test` 与两端 build；
回主工作区 `git merge --ff-only <branch>`；`tools/agent-worktree.sh --remove <name>`；`git branch -d <branch>`；
把对应 ticket 的 Status 从 `fixed-pending-merge` / `ready-for-human` 按实际情况改成 `done` 或保留验收缺口；
`git status -sb` 报告 ahead 数。**不 push。**
