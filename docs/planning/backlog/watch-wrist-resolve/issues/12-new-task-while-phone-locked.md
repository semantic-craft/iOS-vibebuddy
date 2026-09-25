# 12: 手机锁屏后开始的任务，手表列表里一直没有

**What to build:** 手表 App 回到前台时，自己向手机要一次 Mac 的最新状态（节流），这样手机锁屏后才开始的任务也能出现在手表列表上，不用先打开某个任务详情。

**Status:** done（#309；2026-09-25 18:56 腕上通过）

## 为什么

2026-09-25 腕上一轮（`~/Projects/_shared-work/iOS-vibebuddy/watch-round-2026-09-25/RESULTS.md`）：14:57–15:27 之间你在手表上打开了 4 次 App，那个手机锁屏后才开始的任务（ac306851，`sleep 1800`）一次都没出现，没法从手表停下。手表诊断里只有 `window.active` ×4，没有任何刷新请求。

原因：
- 手表上的列表只来自手机写的 application context。手机锁屏后到 Mac 的流断了，不再写新的 context。
- `WatchStateStore.becameActive()` 只重读已有的 `receivedApplicationContext`，从不向手机要新状态。只有任务详情的 `refreshTask()` 会发 `WatchRefreshRequest`。
- 手表的 `sendMessage` 能唤醒锁屏的手机，手机再经 HTTP 读 Mac 快照：锁屏时，14:56 的详情页刷新拿到了 `refresh.received`；15:45 那次第一下 `refresh.failed`（15:45:39），6 s 后第二下成功（15:45:46）。所以路是通的，只是回到前台时没人走；刚打开 App 的头几秒手机可能还不可达。

## 验收

- [x] 手表 App 回到前台、且手机在范围内时，发一次 `WatchRefreshRequest`；手机回来的快照装进列表。回到前台时手机还不可达，等手机变为可达再发。
- [x] 节流：同一时间只有一个；成功后 15 s 内不重发，失败后 3 s 内不重发。不影响详情页自己的刷新（转圈、失败提示都不动）。
- [x] 刷新拿到的状态按「积压」装入，不再震一次：那段时间的提醒推送已经到过手表。手机答复时会把同一份快照也写进 context，刷新在途时这份 context 也按积压装入，不论哪份先到。
- [x] 诊断记 `refresh.active.request` / `refresh.active.received` / `refresh.active.failed`；没发出时记原因 `refresh.active.skip.unreachable|no-state|detail|paced`。
- [x] 回归测试：节流规则（一次一个、成功后 15 s、失败后 3 s、别人的回复不算）。
- [x] 模拟器：手机 App 退到后台、流断后在 Mac 上开始新任务，打开手表 App，新任务出现，不需要打开详情。
- [ ] 真机：手机锁屏后开始一个任务，打开手表 App，它出现在列表上（下一轮腕上）。

## Comments

- 2026-09-25 实现（PR #309）：`WatchActivationRefreshPolicy`（Kit）管节流；`WatchStateStore.linkChanged` 在前台时调 `refreshOnActivation()`，所以窗口回到前台、或前台时手机变为可达都会发。失败后 3 s 内被拦下的那次，到期补发一次。详情页刷新在途时不发；换 Mac 或换配对时清空节流。
- 评审（Opus，MERGE WITH FIXES）已修：context 与回复谁先到都不震；没发出时记原因；发送失败后 3 s 内被拦下的那次到期补发；换配对时释放名额；详情刷新已在途时不再发；测试逐步断言。复审（MERGE）留下的 nit：从通知冷启动直接进详情页时，活动刷新先发、详情刷新随后也发，手机会被叫醒两次，详情刷新的回复若先到仍可能震一下；影响小，未改。
- 已知：手机处理刷新时照常跑它的声音和本地通知规则（详情页刷新原本也是这样）。锁屏期间完成、而 Mac 没推 `agent_done` 的任务，可能在抬腕时由手机补一条本地通知、镜像到手表。这是手机那一侧的既有行为，本票不改。
- 2026-09-25 模拟器（watchOS 27 / iOS 27 自建一对，隔离 daemon :18779，驱动与截图在 `~/Projects/_shared-work/iOS-vibebuddy/wr12-sim-2026-09-25/`）：
  - 冷启动：16:41:45 `window.active` 时手机还不可达，记 `refresh.active.skip.unreachable`；16:41:49 手机变可达，自动 `refresh.active.request`，16:41:54 `received`，列表出现 wr12-before。
  - 场景：手机 App 退到后台，16:43:26 在 Mac 上开始 wr12-after，此后 15 s 手机 App 没有任何日志。16:43:44 手表 App 回到前台 → `refresh.active.request`；手机 16:43:50 被这条消息唤醒（机器负载约 450，唤醒慢），重连流、取 `/snapshot` 并写 context；手表 16:43:52 起收到，截图里 wr12-after 在列表上，未打开详情。这次回复没赶上 12 s 超时（记 `refresh.active.failed`），新状态走的是 context，按积压装入。真机锁屏时流不一定重连，那时靠回复本身（锁屏下的详情刷新已证明能回来）。
  - 顺带：16:43:45 窗口又一次 active 时刷新在途，记 `refresh.active.skip.paced`，没重复唤醒手机。
- 2026-09-25 腕上：手机锁屏后在 Mac 上开 Grok 任务；第一次抬腕 2 s 内请求失败（手机还不可达），第二次抬腕请求后 1.3 s `refresh.active.received`，手机同步给手表的状态里有这条任务。

## 不在本票

- 中继状态只看流（锁屏时刷新成功也显示「连不上 Mac」），见票 08 的可选项。
