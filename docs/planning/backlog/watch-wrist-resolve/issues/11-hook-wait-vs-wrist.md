# 11: Mac 只等 25 秒，手表上的操作常常来不及

**What to build:** 让手表上来得及回答。先量一下真机上从推送到手表点击送达 Mac 的时间分布，再决定：延长等待、到时间后仍接受「对得上那一轮」的迟到回答，还是在手表上显示倒计时。

**Status:** ready-for-human（已实现；生效要重装一次 Claude hook；剩真机：卡片上回答一次，超过 25 s 也能送到）

## 为什么

`VibeBuddyServer.approvalTimeout` 默认 25 s，Claude hook 的超时是 30 s。2026-09-24 腕上验收：从推送到 Mac 收到：横幅批准 / 拒绝 5–9 s，托管 Cursor 的横幅批准约 12 s，走卡片 20 s。一共 9 次过期：agent 先发题、后通知你，1 次；没戴表 1 次；VibeBuddy 开着时不弹横幅 2 次；推送已被苹果接受但手表没震 2 次（原因不明；当时手机朝上，但同一时段另三次正常送达）；横幅「回复」直接打开 App、没带文字 2 次（见 09）；卡片上多点一下「回复」再选答案，来不及 1 次。11:55 那条叫醒手机的推送（`wake1`）也过期了，它不算在这 9 次里。托管的 Cursor 审批没有这个时限，照常通过。

上限：Claude hook 本身的超时是 30 s（`HookInstallerClaude.approvalTimeout`），不重装 hook 最多只能多等约 5 s；hook 放行后 CLI 会自己弹提示，这时再到的回答已经无处可送。

另记体验问题：卡片打开后要先点卡片里的「回复」，才会出现 Yes / No，多了一下点击。

## 测量（2026-09-24 那一轮，Mac 投递记录 + 手表诊断 + hook 输出文件的时间）

| 路径 | 推送到手表点击 | 推送到 Mac 收到 |
| --- | --- | --- |
| 横幅批准 / 拒绝（3 次） | 约 4–8 s | 5–9 s |
| 托管 Cursor 横幅批准 | 约 10 s | 约 12 s（没有时限） |
| 横幅「回复」→ 卡片（3 次） | 4.3 / 6.5 / 9.3 s 打开 App | 都没送到（2 次在等横幅口述，1 次在卡片上超过 25 s） |
| 点通知进卡片 → 选「Yes」→ 双指互点两下 | 8.5 s 打开 App | 20.1 s（在 App 里用了约 12 s） |

结论：横幅上的决定离 25 s 还远；回答只能走卡片（见 09），而卡片这条路要 16–25 s 以上，正好压在线上。9 次过期里，真正是时间不够的是卡片那 1 次，加上 2 次「回复」（原本会走卡片）；其余 6 次是没弹横幅、没震、没戴表、agent 先问后通知，延长等待也救不了。

## 决定（2026-09-25）

**只在 Mac 前没人时，Claude 的审批和提问多等到 60 s。** presence 判断本来就在：会话所在的终端在前台、且最近在用，就立即交给 CLI 自己的提示。这里的「没人」其实是「这个终端不在前台」，所以人在 Mac 上用别的 App 时也会进入 60 s 等待；为此等待期间每秒重新判断一次，一回到那个终端，1 s 内就交还给 CLI 的提示。等待中 Mac 上的卡片照样能答。无头的 `vibebuddyd` 不判断 presence，它下面的 Claude 等待会等满 60 s。

- hook 命令带上它允许的等待：`approval-hook.sh claude 60`，hook 自身超时改为 75 s；脚本把 `hold=60` 带给 daemon，curl 上限改为 70 s。
- daemon 只在两处用这个 hold：Claude 的 `PermissionRequest`，和 Claude 的 `AskUserQuestion`；两处都先问过 presence。旧式的 `PreToolUse` 审批门不问 presence，仍按 25 s。不带 hold 的调用（旧的 hook 配置、Codex、Cursor、Grok）一律 25 s，这样旧配置不会出现 hook 在 30 s 被 Claude 杀掉、而手机上的卡片还显示可答的情况。hold 限在 25–120 s 之间。
- 不采用：到时后仍接受迟到的回答（held-decision 队列，ADR-0032）：hook 放行后 Claude 已经弹出自己的提示，迟到的回答没有地方送；手表上显示倒计时：不解决问题，还要多占一行屏幕；去掉卡片上多点的那一下：那一下是长看界面上的「回复」本身（见 09），App 里省不掉。
- Grok 通过 `[compat.claude]` 会执行带参数的 Claude hook：`approval-hook.sh` 见到 `GROK_SESSION_ID` 且来源不是 `grok` 就立即退出，Grok 会话只由 Grok 自己的审批门来问。脚本对 hold 做与 daemon 相同的 25–120 s 限制，并去掉前导零（避免按八进制算），curl 永远不会比 daemon 先放弃。
- 已知遗留（未改）：用户在 Claude 里按 Esc 中断后 hook 进程被杀，daemon 不知道，卡片最多还能答 60 s（原来 25 s），这期间的回答会被接受后丢掉。可另开票：检测客户端断开。
- 生效条件：新的 Mac App 部署到 /Applications 后，还要在「设置 → Install / repair」重装一次 hook（App 启动时不会改 agent 的配置）。Codex、Cursor、Grok 的 hook 配置不动（Codex 的信任哈希不会失效）。

## Comments

- 2026-09-25 评审（Opus，MERGE WITH FIXES）：阻断项是 Grok 的 `[compat.claude]` 会执行带参数的 Claude 审批门（已修，脚本见 `GROK_SESSION_ID` 就退出，有测试）；另修了健康检测认不出 `claude 60`、脚本 hold 的上下限与八进制、「坐在 Mac 前体验不变」的说法（改为等待中每秒重判 presence），并补了提问路径与 presence 交还的测试。
