# 12: 手机锁屏后开始的任务，手表列表里一直没有

**What to build:** 手表 App 回到前台时，自己向手机要一次 Mac 的最新状态（节流），这样手机锁屏后才开始的任务也能出现在手表列表上，不用先打开某个任务详情。

**Status:** ready-for-agent

## 为什么

2026-09-25 腕上一轮（`~/Projects/_shared-work/iOS-vibebuddy/watch-round-2026-09-25/RESULTS.md`）：14:57–15:27 之间你在手表上打开了 4 次 App，那个手机锁屏后才开始的任务（ac306851，`sleep 1800`）一次都没出现，没法从手表停下。手表诊断里只有 `window.active` ×4，没有任何刷新请求。

原因：
- 手表上的列表只来自手机写的 application context。手机锁屏后到 Mac 的流断了，不再写新的 context。
- `WatchStateStore.becameActive()` 只重读已有的 `receivedApplicationContext`，从不向手机要新状态。只有任务详情的 `refreshTask()` 会发 `WatchRefreshRequest`。
- 手表的 `sendMessage` 能唤醒锁屏的手机，手机再经 HTTP 读 Mac 快照：14:56 和 15:45 锁屏时，详情页的刷新都拿到了 `refresh.received`。所以路是通的，只是回到前台时没人走。

## 验收

- [ ] 手表 App 回到前台、且手机在范围内时，发一次 `WatchRefreshRequest`；手机回来的快照装进列表。回到前台时手机还不可达，等手机变为可达再发。
- [ ] 节流：同一时间只有一个；成功后 15 s 内不重发，失败后 3 s 内不重发。不影响详情页自己的刷新（转圈、失败提示都不动）。
- [ ] 刷新拿到的状态按「积压」装入，不再震一次：那段时间的提醒推送已经到过手表。
- [ ] 诊断记 `refresh.active.request` / `refresh.active.received` / `refresh.active.failed`。
- [ ] 回归测试：节流规则（一次一个、成功后 15 s、失败后 3 s、别人的回复不算）。
- [ ] 模拟器：手机 App 退到后台、流断后在 Mac 上开始新任务，打开手表 App，新任务出现，不需要打开详情。
- [ ] 真机：手机锁屏后开始一个任务，打开手表 App，它出现在列表上（下一轮腕上）。

## 不在本票

- 中继状态只看流（锁屏时刷新成功也显示「连不上 Mac」），见票 08 的可选项。
