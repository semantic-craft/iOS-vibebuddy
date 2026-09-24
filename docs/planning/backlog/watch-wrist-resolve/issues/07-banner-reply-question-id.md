# 07: 通知里带上 question id，让手表横幅回答不再靠推断

> 2026-09-23 从 `_shared-work` 移入仓库（`docs/planning/backlog/`）。Mac 与 iPhone 的通知负载已带 `questionId`（#248），剩下手表侧在持有时绑定。

**What to build:** 在通知的 `userInfo` 里像 `approvalId` 一样带上待答问题的 id，让手表从横幅「回答」发出的听写直接绑定到它本来要回答的那个问题，而不是靠第一份中继状态去推断。涉及 APNs 负载与两侧通知构造（`APNs.swift`、Mac 侧 notifier、iPhone 侧 `LocalNotifier`），手表侧读出后塞进 `WatchNotificationResponseRoute.resolve`，`WatchBannerAction` 在持有那一刻就完成绑定。

**Blocked by:** PR #249（ADR-0033，横幅动作在点击设备上执行）

**Status:** needs-triage（代码已完成，模拟器已验；真机上横幅口述走不到，等 [09](09-banner-reply-opens-app.md) 定方案）

**Blocked by:** 09

## 为什么

ADR-0033 让手表横幅的「批准 / 拒绝 / 回答」在手表上执行。批准有 `approvalId` 随通知到达，绑定是确定的；问题没有对应的 id，所以回答只能绑到「这个会话当前在问的问题」。

PR #249 的做法是：取第一份**中继**状态里该会话正在问的问题作为绑定，此后不再移动。这把窗口收敛到「点击到第一份中继状态之间」，但没有消灭它——那段时间手表只有磁盘缓存，而 `WatchStoredState` 会把 `pendingId` 抹掉，绑不了任何东西。若 agent 恰好在这段时间答完旧问题、问了新问题，听写会被继承到新问题上，`WatchSessionActionGate` 还会接受，因为那个 id 确实是活的。

这个洞在评审中被移动过一次：绑定原先放在 `hasRelayedState && isLive(state)` 之后，而 `isLive` 要求手机可达——可达不了正是持有等待的时候，于是窗口被拉长到整个 8 秒 patience。86106712 已修（只要 `hasRelayedState` 就绑定）。只有通知自带 question id 才能真正关掉它。

## 验收

- [x] 通知 `userInfo` 带 question id，Mac 与 iPhone 两侧构造一致；旧版本手机发来的、不带该 id 的通知仍按现有「第一份中继状态绑定」降级，不崩不误发。
- [x] 手表从横幅回答时，绑定在**持有那一刻**完成，不依赖任何后续状态。
- [ ] 真机：手表横幅听写一次回答，Mac 收到的答案对应横幅上那个问题；在听写与发送之间让 agent 换一个问题，结果是被拒绝并在卡片上留下句子，而不是答到新问题上。
- [x] 多段问题（`questions != nil`）仍然拒绝单串回答，走卡片上的逐题流程。
- [x] ADR-0033 residual 段落改写为已关闭，或写明剩余边界。

## Comments

- 2026-09-22：顺带处理一个够不着的默认值——`WatchStateStore.settleBannerAction` 发送分支里 `.open` / `.ignore` 写的是 `started = false`，若被走到会误报 `giveUp`。`perform` 的 `route.isAction` 闸门加上 alert 查找两道都排除了它们，所以目前不可达；本票会动到这个 switch，顺手改成 `true`（「没有要发的东西」不是失败）。两个并行会话都确认过不可达，因此没有为它单开提交。
- 2026-09-23 triage + 实现：Mac（`APNs.swift` / `VibeBuddyServer`）与 iPhone（`Notifier.swift`）自 #248 起已带 `questionId`，本票只剩手表侧。改动：
  - `WatchNotificationResponseRoute.answer` 带上 `questionID`（`WatchAppDelegate` 从 `userInfo` 读出）；`WatchBannerAction` 在持有时即绑定，任何后续状态都挪不动。没有 `questionId` 的旧通知照旧在第一份中继状态绑定（诊断记为 `notification.action-answer-unbound`，有 id 的是 `notification.action-answer`）。
  - 去向由纯函数 `WatchBannerAction.replyStanding` 决定：绑定的问题 → 能一串答完就发；会话在问**另一个**问题 → 先按缺席持有（冷启动的第一份状态可能早于通知），更新的 revision 仍是别的问题或 8 秒耐心用完时拒绝（`.noLongerWaiting`）；手表上没有 id 的问题 → `.notDecidableHere`；什么都没问 → 只有更新的 revision 才算已结束。
  - 被拒的听写不丢：卡片上显示「Not sent: “…”」（`unsentBannerReply`），能一串作答时另给 **Use my reply**，走普通确认页、对准*当前*问题——改投哪一题由佩戴者决定。卡片关闭、新的横幅回答取代、或该会话**之后**的回答到达 iPhone/Mac 时才清掉（`WatchUnsentReply.isSuperseded` 只认变化）。已从手表发出、却被 iPhone 拒绝或失败的横幅回答，文字同样放回卡片（`restored`；`unknown` 不放，Mac 可能已收到）。
  - 顺手：`settleBannerAction` 的 `.open` / `.ignore` 不再算失败，直接 `return`（不留句子、不记 `banner.action-sent`）。
  - 剩余边界写在 ADR-0033 决策 5 的 Residual 段。
- 手表真机验收步骤（owner）：先装含本改动的 iPhone + Watch 构建，**用新发出的通知**（旧横幅保留旧 category）；手机锁屏、手表戴好。
  1. 让 agent 问一个单段问题（如 Claude `AskUserQuestion` 单题）。手表横幅点 Reply，口述一句并发送。预期：卡片打开，轻敲一次；Mac 收到的回答对应横幅上的那个问题。
  2. 换题拒绝：让 agent 问问题 A；在手表横幅点 Reply、开始口述时，在 Mac 上把 A 答掉并让 agent 立刻问问题 B；再在手表上发送。预期：不发送（最多等约 8 秒）；卡片显示「这项请求已经不需要你处理了」+「未发送：“你说的话”」，双击震动；B 下方有「用我的回答」，点开确认页显示的是 B，确认后才发到 B。
  3. 多段问题：让 agent 问两题以上的问题，横幅 Reply 口述一句。预期：不发送，卡片说「只能在 iPhone 或 Mac 上处理」（或走逐题流程），口述内容仍显示在卡片上。
  4. 可选：诊断里点 Reply 那一刻应记为 `notification.action-answer`（不是 `-unbound`），证明通知带了 `questionId`。
- 2026-09-24 模拟器验收（成对的 iPhone 17 Pro iOS 27.0 + Watch Series 11 watchOS 27.0，隔离 daemon :18777，开发版 `main` 9137f92f）：带 `questionId` 的横幅回答在持有时绑定，送达后 agent 收到的正是那一题；在 Mac 上答掉 A 并问 B 之后，横幅回答等约 8.6 s 被拒（`banner.action-fallback.noLongerWaiting`），卡片显示 “The banner's button wasn't sent: this is no longer waiting on you.” / “Not sent: …”，B 没被回答；两段问题拒绝（`notDecidableHere`），口述留在卡片；不带 id 的旧通知记为 `notification.action-answer-unbound`，在首份中继状态绑定后送达；手表发往手机失败的回答同样把文字放回卡片。限制：手表 App 不申请通知权限，`simctl push` 到手表模拟器会被拒；Xcode 27 的 Device Hub 也没有可操作的窗口。所以点击由本地临时注入代替（未提交），注入调用的就是 `WatchNotificationResponseRoute.resolve` → `WatchNotificationRouter.route`，之后全是正式代码。「Use my reply」模拟器上没点，设备这一轮也不点，照实记为未验。hook 等待只有 25 s（`approvalTimeout`），而手表发出后到 Mac 还要约 11–13 s（2026-09-23 那一轮），所以腕上每步要在横幅到后 10 s 内做完。记录：`~/Projects/_shared-work/iOS-vibebuddy/watch-acceptance-2026-09-24/RESULTS.md`。剩下的真机勾选项并入 backlog README「只剩你」第 1 件（第 2、3 步）：「留下句子」由你在第 3 步回答有 / 没有，拒绝由诊断里的 `banner.action-fallback.noLongerWaiting` 和 B 没被回答来确认。
- 2026-09-24 腕上验收（Hermes 开发版 1.3.28 (58)，`main` 9137f92f；手表 Series 10，watchOS 27；Mac 1.3.32 开发版，:9876）：**横幅口述这条路径在这块表上走不到。** 三次点横幅「回复」，推送后 5–10 s 诊断都记为 `notification.action-opens`（没带到文字），打开的是 App 自己的卡片，不是系统输入框。什么都没发出去，是安全的，但上面 owner 步骤的第 1–4 步都依赖横幅口述，全都无法按原设计验收。转到 [09](09-banner-reply-opens-app.md) 定方案。走卡片回答正常：点横幅文字 → 卡片 → 预设「Yes」+ 双指互点两下，agent 收到的正是那一题（推送后 20 s）。绑定逻辑本身已在模拟器上验过（见上一条）。
