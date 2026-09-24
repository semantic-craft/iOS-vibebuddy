# 08: 手机锁屏时，手表上的「停下」发不出去

**What to build:** 手机锁屏时，从手表发出的「停下」也能送到 Mac。手表不再只因中继状态显示「iPhone 没连上 Mac」就拒绝发送；手机收到时，用保存的配对立刻试一次（学 #260 的「流断不等于 Mac 不在」，但不走它的持有队列），结果照实告诉手表。

**Status:** ready-for-agent

## 为什么

2026-09-24 腕上验收（`~/Projects/_shared-work/iOS-vibebuddy/watch-acceptance-2026-09-24/RESULTS.md`）：
- 手机锁屏时，手表「停下」+ 双指互点两下确认后，手表显示 iPhone 没连上 Mac；Mac 日志里没有停下，任务把 `sleep 600` 跑完了。同一步手机解锁后通过，12:04:55 记为 `userStopped`。
- 锁屏手机上，手表的刷新仍能经手机从 Mac 拿到快照（诊断里有 `refresh.received`），可中继状态一直是 `macDisconnected`：流断了，不等于 Mac 不可达。#260 为审批和回答修了同一个误判，停下被 ADR-0032 明确排除在外。

三处都卡住了：
- 手表按钮：`WatchStopControl.blocked` 调 `WatchLinkBlock.message`，在 `.macDisconnected` 时显示「Your iPhone can't reach your Mac, so this can't be sent.」并把按钮禁用。你当时看到的多半就是这句。
- 手表发送：`WatchStateStore.submitStop` 要求 `isLive`，`.macDisconnected` 直接失败。
- 手机：`DashboardStore.actFromWatch` 在 `state != .connected` 时，停下被 `hold()` 的 `!action.isDestructive` 挡掉，既不持有也不试。

同一个误判也让手表重启后一直停在「连不上 Mac」：锁屏时 `refreshForWatch` 确实从 Mac 拿到了快照，但回给手表的中继状态只看流（`state == .connected ? .live : .disconnected`）。11:53–11:56 那段，下拉刷新也没发出请求（诊断里没有 `refresh.request`）。

## 验收

- [ ] 手表：中继状态为 `.macDisconnected` 且手机可达时，停下按钮可点，不显示阻断文字，照样发给手机；手机不可达时仍然禁用。
- [ ] 手机：流断时，按这个顺序走一次：`actionSnapshot` → `watchActions.admit(request, sessions: snapshot.sessions)`（拿手表那次点击的 `statusSince` 去比）→ `phoneStop`。不调 `hold` / `deliverHeldNow` / `pendingActions`，`hold()` 里的 `!action.isDestructive` 保留；没有重试。
- [ ] 结果按 `StopDelivery` 映射：accepted → `accepted`，refused → `refused`，failed → `failed`，unconfirmed → `unknown`。取快照失败（什么都没发出去）→ `failed`，并带上原因。
- [ ] 不变：停下从不排队、从不迟到；目标轮次变了，由手机按快照拒绝，Mac 再按 `expectedStatusSince` 拒绝一次。
- [ ] 回归测试覆盖三种情况：流断时停下送达；Mac 真不可达就失败，之后的 flush 也不发它；目标轮次已被取代就 `refused`，不 POST。
- [ ] 可选，或另开票：中继状态不再只看流（锁屏时刷新成功应算连着），并让手表的下拉刷新能发出请求。
- [ ] ADR-0032 补一段修订：停下也用一次立即尝试，但仍不持有。
- [ ] 真机：手机锁屏，手表停下一个在跑的托管任务，Mac 记为 `userStopped`（agent 可在下次腕上验收里顺带做）。
