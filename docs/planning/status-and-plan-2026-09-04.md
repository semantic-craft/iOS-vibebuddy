# vibebuddy — 进度与下一步（2026-09-04）

**本文取代 `status-and-plan-2026-09-03.md`**，是当前唯一的"下一步"来源。
09-03 那份是当天的过程存档，不要再当基线读。

基线：`main` = `origin/main` = `fbe199a`
（`feat(codex): jump to a Desktop thread in ChatGPT.app instead of hiding the button (#15)`）。
本会话在 `feat/bookkeeping` 上实跑：VibeBuddyKit `swift test` **218 / 26 套件**，
VibeBuddyMac `swift test` **468 / 44 套件**，全绿。未跑 Xcode 构建。

## 一、四个开发会话

| 会话 | 内容 | 结果 |
|---|---|---|
| M | 合计划 PR + PR #8，再按 C2 → C1 → C3 → B 收 | **已合** PR #13（`7182457`）、#8（`f28da09`）、#14（`dd943a0`）、#15（`fbe199a`）。C3 尚未出 PR。B = PR #17（本文件，未合） |
| C1 | Desktop 线程跳进 ChatGPT.app（ticket 04） | **已合** PR #15 = `fbe199a`。本机跳转验证过前置；iPhone 目视与是否切到指定对话留给 H2。票 = `ready-for-human`，**不是 done** |
| C2 | 空 bearer 失败关闭 + UserDefaults 默认值 + 子进程回收测试 | **已合** PR #14 = `dd943a0` |
| C3 | ticket 06 → 02：健康诊断与递归发现一致；无主线程收敛 | **进行中，无 PR。** worktree `feat/codex-observation-trust`：06 已有本地提交 `9232729`（`CodexRolloutDiscovery`）；02 有未提交改动。两票都被 C3 标成 `fixed-pending-merge`。锁实证写在票 02 Comments，B 未复跑 |

## 二、还开着的代码

只剩 C3 两票，**都还没进 main**。main 上 `ObservationHealthDetector.latestRollout`（约 351 行）仍是 `for daysAgo in 0...1`；
`CodexRolloutMonitor.candidateFiles` 已用 `FileManager.enumerator`（PR #8）。C3 本地 `9232729` 把发现抽到 `CodexRolloutDiscovery`，两边共用；02 的无主收敛还停在该 worktree 的未提交 diff 里。

架构边界票第 2–6 步已在 main（见该票 Comments）。第 1 步（Kit 表面分组）**不做**，理由在票里，不另开新票。

## 三、人工事项（一次只开一个；独占已装 App / `:9876` / 手机）

1. **H1 Sparkle 上线三步**（ticket `mac-power-features/07` = `ready-for-human`）
   开 `gh-pages`（`git ls-remote --heads origin gh-pages` 此刻为空）→ 发 v1.1 Release + appcast → 真机走一次应用内更新。
   前置：波 2（C3 + B）进 main。签名 / 公证 / staple 以 ticket 07 所记为准（B 未重跑 `spctl`）；缺的是 Pages 与真机更新。
2. **H2 装机验收**（Mac + iPhone）
   Codex Desktop 真实线程（ticket 01 + C1 跳转目视）、observability 03 / 04 / 06、
   iPhone 三项目视（五态颜色 / Live Activity / Widget）、acceptance 01 目视、6 月遗留清单。
   前置：H1 完成、App 在跑、手机已配对。
3. **H3 真机 Watch 验收**（ticket 08 = `ready-for-agent`，需要你 + 真表）
   W1–W3 = `done`（模拟器）；W4–W7 = `merged-pending-device-acceptance`。
   前置：H2。**不需要 TestFlight**——Xcode 直装 iPhone，watchOS app 内嵌会跟着装上。

## 四、不做清单（以后不用重新论证）

- **App Store 公开提交：搁置。** 个人项目，审核 + 商店文案 + 隐私标签 + 截图是纯人力、零个人收益。
  `tools/archive-ios.sh` 与 `docs/app-store-listing.md` / `app-store-paste-sheet.md` / `app-store-submission-checklist.md` 原样归档，不删。
- **R2 / TestFlight：从关键路径移除。** 脚本里 `-exportArchive`（约 254 行）和 Apple Distribution 身份只有上传 TestFlight 或商店才需要。
  真机 Watch 验收用 Xcode 直装 iPhone（P1 已这么做过）。
- **codex-desktop 03 / 05 / 07 / 08 / 09 / 10：保持 `deferred`。** 理由已在各票（私有 sqlite schema、锦上添花、上游 hook 不可靠、不留双源回退、本机无 `.zst`、本机无 IDE 根目录）。收尾期不重开。
- **codex-desktop 11：`wontfix`。** rollout 已有 `task_complete`；`notify` 单槽且会被 Desktop 插件覆盖。
- **antigravity hooks：`blocked-upstream`。** agy 1.0.5/1.0.6 加载但不执行 hooks，上游 `google-antigravity/antigravity-cli#222`。接线在 main，等上游。
- **Cursor 云端 agent 不用于本仓库的开发。** 云端 VM 是 Linux，没有 Swift / Xcode、没有 `~/.codex`、没有 `.scratch` 与 `.claude`（gitignore）。只有纯文档能上云，不值得为它分裂流程。

## 五、当前提示词

任务与提示词见 `docs/planning/plan-remaining-work.html`。
`docs/planning/prompts-2026-09.md` 的任务集已退役；它的「通用约束」一节仍有效。
