# 09: 挂起的 `Stop` 只按已知子代理的 `SubagentStop` 扣减

**Status:** ready-for-agent

**Blocked by:** None（AI-04 [票 04](04-claude-stop-background-tasks.md) 已合并并验收）

## 问题

AI-04 规定：只被 subagent 挂起的主 agent `Stop`，收到与挂起时数量相同的 `SubagentStop`、且没有仍在跑的子代理后，进入 45 s 宽限（`SessionReducer.heldStopReleaseGrace`），之后落定并提醒完成。

2026-09-24 真实会话验收（票 04 Comments 末条）发现：多数轮次都有 1 条或以上 CLI 内部代理的 `SubagentStop`（`agent_type` 为空），它们没有对应的 `SubagentStart`。现在任何 `SubagentStop` 都会扣减 `HeldStop.awaitedSubagentStops`，所以这些内部代理会先把计数扣到 0。目前靠「仍有 running 子代理」这条检查兜住。

兜不住的情况：真正子代理的 `SubagentStart` 丢了（async hook 投递丢失、daemon 在它启动后才起来）。这时子代理拓扑里没有它，内部代理把计数扣到 0 后，「仍有 running 子代理」也为假，宽限提前开始；45 s 后这一轮落定并响完成提醒，而真正的后台子代理还在跑。

## 修复方向

- 只有结束了一个**已知正在运行**的子代理（见过它的 `SubagentStart`，子代理拓扑里状态为 running）的 `SubagentStop` 才扣减 `awaitedSubagentStops`、才可能开启宽限。
- 未知子代理的 `SubagentStop`（包括没有 `agent_id` 的）不影响挂起的 `Stop`。这样丢了 `SubagentStart` 的挂起轮次不会被提前放行，只能由更新的主 agent `Stop` 或 10 分钟兜底释放，与 workflow / teammate 的处理相同。
- AI-04 其余规则不变（数组为准、shell 等不挂起、`/loop` 安静落定、迟到回执不重开、兜底与恢复会话退役）。

## 验收

- [ ] Reducer 测试：挂起时有一个已知子代理和一个 `SubagentStart` 丢失的子代理；两条未知 `SubagentStop` 不扣减、不开启宽限；已知子代理结束后计数只减 1，宽限仍不开始；10 分钟兜底照常释放。
- [ ] Reducer 测试：只有一个已知子代理时，它的 `SubagentStop` 照常开启 45 s 宽限（前面夹着的内部代理 `SubagentStop` 不影响）。
- [ ] 现有 AI-04 测试（`ClaudeBackgroundWorkTests`）不改断言、全部通过；全量 `cd VibeBuddyMac && swift test` 通过。
- [ ] `CONTEXT.md`「Background work at a Claude Stop」写明只数已知子代理的结束。

## Comments
