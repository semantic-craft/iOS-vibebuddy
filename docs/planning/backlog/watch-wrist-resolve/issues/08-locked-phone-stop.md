# 08: 手机锁屏时，手表上的「停下」发不出去

**What to build:** 手机锁屏时，从手表发出的「停下」也能送到 Mac。手表不再只因中继状态显示「iPhone 没连上 Mac」就拒绝发送；手机收到时，按 #260 给审批的做法，用保存的配对直接试一次（不排队），结果照实告诉手表。

**Status:** ready-for-agent

## 为什么

2026-09-24 腕上验收（`~/Projects/_shared-work/iOS-vibebuddy/watch-acceptance-2026-09-24/RESULTS.md`）：
- 手机锁屏时，手表「停下」+ 双指互点两下确认后，手表显示 iPhone 没连上 Mac；Mac 日志里没有停下，任务把 `sleep 600` 跑完了。同一步手机解锁后通过，12:04:55 记为 `userStopped`。
- 锁屏手机上，手表的刷新仍能经手机从 Mac 拿到快照（诊断里有 `refresh.received`），可中继状态一直是 `macDisconnected`：流断了，不等于 Mac 不可达。#260 为审批和回答修了同一个误判，停下被 ADR-0032 明确排除在外。

两处都卡住了：
- 手表：`WatchStateStore.submitStop` 要求 `isLive`，`.macDisconnected` 直接失败。
- 手机：`DashboardStore.actFromWatch` 在 `state != .connected` 时，停下既不持有也不试。

## 验收

- [ ] 手表：中继状态为 `.macDisconnected` 且手机可达时，停下照样发给手机；手机不可达时仍拒绝。
- [ ] 手机：流断时，停下只用保存的配对立即试一次 `/answer`（intent stop，带 `expectedStatusSince`），不进持有队列；送达回 `accepted`，Mac 回 409 回 `refused`，传输失败回 `failed` 并带上原因。
- [ ] 不变：停下从不排队、从不迟到；目标轮次变了由 Mac 拒绝（`expectedStatusSince`）。
- [ ] 回归测试覆盖「流断时停下送达」和「流断时 Mac 真不可达就失败」。
- [ ] ADR-0032 补一段修订：停下也用一次立即尝试，但仍不持有。
- [ ] 真机：手机锁屏，手表停下一个在跑的托管任务，Mac 记为 `userStopped`（agent 可在下次腕上验收里顺带做）。
