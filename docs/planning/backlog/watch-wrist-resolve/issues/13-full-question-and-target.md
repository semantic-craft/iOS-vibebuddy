# 13（M-07）：手表上完整显示问题和审批对象，结果片段可展开

**What to build:** 手表上的问题、审批对象（命令 / 文件 / 工具输入）完整显示，不再截成几行；任务详情里的结果片段可以原地展开。不做腕上朗读（ADR-0021 2026-09-23 修订）。

**Status:** ready-for-human（代码与模拟器已验；腕上一项并入下一轮手表检查）

**Executor:** Claude（Opus 5.5）· 分支 `claude/m07-watch-full-text` · 2026-09-25

## 为什么

截图（改前，40 mm 模拟器，`longText` 演示场景）：

- 可以在手表上批准的命令被截成 4 行：`… && gh pr c…`，下面就是「批准」。没读完的命令不该能批。`WatchApprovalEligibility.maxDetailLength` = 160 字符以内才给批准按钮，但 40 mm 上 mono 10 pt 一行约 23 个字符，4 行只放得下约 90 个，160 字符的命令一定被截。
- 问题标题截成 3 行（`WatchRelayTests expe…`），回答选项截成 2 行（`update WatchRe…`）。问题没读完、选项没读全就要选。
- 答复确认页、多问题逐页作答页里的问题同样截 2–4 行。
- 结果：详情页只有 Mac 生成的摘要（≤ 180 字）或第一行状态（≤ 100 字）；没配摘要时（2026-09-25 移除 Gemini 后常见）常常只剩「结果请在手机上看」。Mac 早就给手机发了 agent 最终回复的第一句（`completionText`，≤ 280 字），手表没收。

## 调研（2026-09-25，读原文）

- Apple HIG Typography：滚动区域里避免截断文字，除非用户能打开别处看全文。HIG Scroll views（watchOS）：优先竖向滚动，长页面没问题。Mail、Messages 在手表上显示全文、用表冠滚动；通知 long look 同样全文可滚，操作按钮在正文下面。
- 同类开源手表 App：
  - shobhit99/claude-watch：命令截到 50 字符，照样能批准（没有长度门槛）；问题在 ScrollView 里全文显示。
  - JoshKappler/apple-watch-claude-code（Pinch）：完整命令放在按钮上方一个可滚动的区域里；因为表冠滚动时可能误批，批准只能点，不能用表冠。
  - b-nnett/codex-apple-watch：卡片只显示 4 行预览，点开是全文阅读页（没有批准功能）。
  - home-assistant/iOS：通知正文不限行数。
- 主流做法有两种：短内容直接全文加表冠滚动；超长内容先给预览，再点开看全文。没有哪个 App 因为命令长就不让在手表上批准。

## 决定

1. **问题和审批对象整段显示**，靠表冠滚动。只有离群的超长文本（超过约两屏 40 mm，`WatchReadingFold.requestLimit` = 600 宽度单位）先给预览，下面一个「展开 / 收起」原地展开。选择「原地展开」而不是另开一页：不多一层导航，按钮位置不变，也符合 HIG「能看到全文才可截断」。
2. **能批准的命令永远不折叠**：`requestLimit` ≥ 2 × `maxDetailLength`，全中文的 160 字命令也放得下（测试钉住）。批准按钮上面就是完整命令。
3. **宽度单位而不是行数**：中日韩字符算 2，其余算 1。中英文在同样的高度折叠，规则是纯函数，可测，与表盘尺寸和字号设置无关。
4. **长问题换小一号字**：超过 120 宽度单位的问题用 13 pt（短问题仍是 15 pt 标题），答案不被推到几屏之外。选项和快捷回复标签完整换行，不再缩字号截断。
5. **结果片段**：`WatchFollowedTask` 新增可选字段 `resultExcerpt`，取 Mac 已发给手机的 `completionText`（只取已完成、有 `completionID` 的这一轮；不进 WidgetKit / 表盘）。详情页依次显示「Mac 生成的完成摘要」和「agent 回复的开头」，各自一段，超过约 4 行（`resultLimit` = 110）就给「展开」。都没有时回落到原来的状态摘要 / 「结果请在手机上看」。
6. **保留 160 字符的批准门槛**（不采纳调研里「放开长度」的建议）：这条规则同时是 iPhone 的放行闸（`WatchSessionActionGate`），放宽属于安全取舍，不是 M-07 的范围；目前没有真实使用里「长命令只能去手机批」的反馈。真用中常碰到再改。
7. **工具输入**：非 Bash / 非文件的工具，Mac 只转发 ≤ 120 字的预览（`ApprovalDetails.commandPreview`），手机卡片显示的也是它。手表整段显示这段预览，与手机一致；要看更多得改 Mac 的转发，不在本票。
8. **不做**：腕上朗读；把完整结果正文拉到手表（要手机每次打开都去 Mac 取正文，完整结果仍在手机上看）。

## 验收

- [x] 可批准的命令在手表上整段显示，批准按钮在完整命令下面（模拟器截图 19）。
- [x] 问题与选项整段显示；答复确认页、逐页作答页的问题也不截（截图 18）。
- [x] 超长、不能在手表上批准的命令先给预览，「展开」后显示全文（截图 20）。
- [x] 完成的任务详情显示 agent 回复的开头，结果片段可展开 / 收起（截图 21、22 中文）。
- [x] 回归测试：`WatchReadingFoldTests`（能批准的命令不折叠、在词边界折叠且保留全文、中日韩字符算 2、结果开头进详情不进表盘）。
- [ ] 真机（并入下一轮手表检查，不单独约）：在你的手表上看一条长问题和一条能批准的长命令：表冠滚到底能读完，点「批准」正常；再点一次结果的「展开」。

## Comments

- 2026-09-25 实现：Kit `WatchReadingFold`（折叠规则，纯函数）+ `WatchFollowedTask.resultExcerpt`；Watch `WatchFoldedText`（整段显示，超限给「展开 / 收起」，VoiceOver 始终读全文），用在提醒卡的问题与命令、答复确认页、逐页作答页，以及任务详情的结果片段。新增演示场景 `longText`，`tools/watch-qa-shots.sh` 增加 18–22 号截图与 `WATCH_QA_SETTLE`（机器负载高时启动 3 s 不够）。
- 验证：`VibeBuddyKit swift test` 493 项通过；`VibeBuddyWatch`（watchOS Simulator）与 `VibeBuddyApp`（generic iOS Simulator，含 Watch）构建通过。40 mm 模拟器改前 / 改后截图（含滚动与点「展开」）在 `~/Projects/_shared-work/iOS-vibebuddy/m07-watch-full-text-2026-09-25/`，对照图 `m07-before-after.png`。
