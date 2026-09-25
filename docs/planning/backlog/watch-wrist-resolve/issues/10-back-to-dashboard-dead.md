# 10: 任务详情页「返回总览」点了没反应

**What to build:** 任务已经不在当前列表里时，详情页的「返回总览」按钮要能回到首页。

**Status:** ready-for-human（已修；剩真机：详情页的任务离开列表后点「返回总览」一次）

## 为什么

2026-09-24 腕上验收：打开一个已离开列表的会话（失败的 Codex 任务）的详情页后，「返回总览」点了没反应，只能强制退出 App。watchOS 27 的强制退出方法是按住侧边按钮直到出现滑块，再按住数码表冠。

## 验收

- [ ] 复现并修复（模拟器上可用 `VIBEBUDDY_WATCH_TASK` 打开一个不存在的任务来复现）。模拟器没复现出来；已加防护和诊断，待真机确认，见 Comments。
- [x] 顺带：列表行上标出 agent（这次两条同名的 wrist-qa，一条 Codex、一条 Cursor，从手表上分不清）。

## Comments

- 2026-09-25 模拟器（watchOS 27，Series 11 46 mm，隔离 daemon :18796，XCUITest 驱动手表）：以下 6 种情况「返回总览」都能回到首页，没有复现：Demo 下打开不存在的任务；真实中继下打开报错任务，再用 `SessionEnd` 让它离开列表；详情页开着时复杂功能换成额度页；先额度页再任务；任务 A 开着时换成任务 B；「停下」确认页开着时任务离开列表。后三种用的是本地临时注入（没提交）。
- 腕上那次的手表诊断只保留 48 条，11:36:09 到 11:47:36 之间的事件已经被冲掉，看不出按钮被点时发生了什么。之后 11:47:52、11:47:59 两次复杂功能 URL 都没有触发 `detail.appeared`，有两种可能：`taskLink` 还是那一个、详情页一直开着；或者 `taskLink` 已是 nil，但页面还卡在屏幕上，再写入一个 link 也弹不出来（如果那两次是额度页的 URL，本来也不会有 `detail.appeared`）。当时的诊断分不开这两种。
- 修法（不依赖复现）：「返回总览」改为由 store 直接清掉 `taskLink`（这个 sheet 本来就由它驱动）；只有在没有打开的 link 时，才退回用环境的 `dismiss()`，并记为 `detail.back-unbound`。另外新记 `detail.back`、`detail.dismissed` 两个事件；`openTask` 按原来的 link 分记 `route.url.same` / `route.url.replace` / `route.url.from-nil`；诊断环从 48 条扩到 200 条（200 条最坏约 12 KB，手机端上限 32 KB）。下一次真机如果再点不动，诊断会直接显示是按钮根本没收到点击，还是 sheet 没关掉。
- 列表行：任务行、报错行的第二行以 agent 开头（如「Codex · usage limit」「Claude」），等待行本来就有。模拟器截图已核对。
- 读下一轮真机日志：只有「`detail.back` 之后没有 `detail.dismissed`」才是按钮失效（`detail.dismissed` 在切换任务、打开额度页、用表冠关页时也会出现）。如果出现 `detail.back-unbound` 却没有 `detail.dismissed`，说明页面卡在屏幕上、背后已没有 link，下一步要让呈现层重建，而不是再调一次 `dismiss()`。
- 评审（Opus，MERGE WITH FIXES）：取消了过早打的勾、改正了上面那句推断，补了 `openTask` 的分记和空 summary 的回退。
