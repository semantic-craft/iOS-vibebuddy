# 07: 通知里带上 question id，让手表横幅回答不再靠推断

> 2026-09-23 从 `_shared-work` 移入仓库（`docs/planning/backlog/`）。Mac 与 iPhone 的通知负载已带 `questionId`（#248），剩下手表侧在持有时绑定。

**What to build:** 在通知的 `userInfo` 里像 `approvalId` 一样带上待答问题的 id，让手表从横幅「回答」发出的听写直接绑定到它本来要回答的那个问题，而不是靠第一份中继状态去推断。涉及 APNs 负载与两侧通知构造（`APNs.swift`、Mac 侧 notifier、iPhone 侧 `LocalNotifier`），手表侧读出后塞进 `WatchNotificationResponseRoute.resolve`，`WatchBannerAction` 在持有那一刻就完成绑定。

**Blocked by:** PR #249（ADR-0033，横幅动作在点击设备上执行）

**Status:** needs-triage

## 为什么

ADR-0033 让手表横幅的「批准 / 拒绝 / 回答」在手表上执行。批准有 `approvalId` 随通知到达，绑定是确定的；问题没有对应的 id，所以回答只能绑到「这个会话当前在问的问题」。

PR #249 的做法是：取第一份**中继**状态里该会话正在问的问题作为绑定，此后不再移动。这把窗口收敛到「点击到第一份中继状态之间」，但没有消灭它——那段时间手表只有磁盘缓存，而 `WatchStoredState` 会把 `pendingId` 抹掉，绑不了任何东西。若 agent 恰好在这段时间答完旧问题、问了新问题，听写会被继承到新问题上，`WatchSessionActionGate` 还会接受，因为那个 id 确实是活的。

这个洞在评审中被移动过一次：绑定原先放在 `hasRelayedState && isLive(state)` 之后，而 `isLive` 要求手机可达——可达不了正是持有等待的时候，于是窗口被拉长到整个 8 秒 patience。86106712 已修（只要 `hasRelayedState` 就绑定）。只有通知自带 question id 才能真正关掉它。

## 验收

- [ ] 通知 `userInfo` 带 question id，Mac 与 iPhone 两侧构造一致；旧版本手机发来的、不带该 id 的通知仍按现有「第一份中继状态绑定」降级，不崩不误发。
- [ ] 手表从横幅回答时，绑定在**持有那一刻**完成，不依赖任何后续状态。
- [ ] 真机：手表横幅听写一次回答，Mac 收到的答案对应横幅上那个问题；在听写与发送之间让 agent 换一个问题，结果是被拒绝并在卡片上留下句子，而不是答到新问题上。
- [ ] 多段问题（`questions != nil`）仍然拒绝单串回答，走卡片上的逐题流程。
- [ ] ADR-0033 residual 段落改写为已关闭，或写明剩余边界。

## Comments

- 2026-09-22：顺带处理一个够不着的默认值——`WatchStateStore.settleBannerAction` 发送分支里 `.open` / `.ignore` 写的是 `started = false`，若被走到会误报 `giveUp`。`perform` 的 `route.isAction` 闸门加上 alert 查找两道都排除了它们，所以目前不可达；本票会动到这个 switch，顺手改成 `true`（「没有要发的东西」不是失败）。两个并行会话都确认过不可达，因此没有为它单开提交。
