# 04: Claude `Stop` 带后台任务或定时循环时不进 done

**What to build:** `HookParser` 读 `Stop` 的 `background_tasks[]`（type ∈ shell/subagent/monitor/workflow/teammate/cloud session/MCP task）与 `session_crons[]`；非空时该 `Stop` 视为"暂停等后台工作"：会话保持 working（或新状态语义按 CONTEXT 决定），完成提醒不发，行上显示"N 项后台工作 / 定时循环"；后续真正的 `Stop`（数组为空）或 `SessionEnd` 才落定。

**Blocked by:** None

**Status:** ready-for-agent

- [ ] `HookParser` 解析并挂到 `HookEvent`（`backgroundTasks`、`sessionCrons`）。
- [ ] Reducer 规则 + 测试（夹具用官方文档形状）。
- [ ] 手机/Mac 行文案。
- [ ] 验收：一个 `/loop 1m` 会话在 Stop 后不响完成提醒。
