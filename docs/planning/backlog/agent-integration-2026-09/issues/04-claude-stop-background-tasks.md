# 04: Claude `Stop` 带后台任务或定时循环时不进 done

**What to build:** `HookParser` 读 `Stop` 的 `background_tasks[]`（type ∈ shell/subagent/monitor/workflow/teammate/cloud session/MCP task）与 `session_crons[]`；非空时该 `Stop` 视为"暂停等后台工作"：会话保持 working（或新状态语义按 CONTEXT 决定），完成提醒不发，行上显示"N 项后台工作 / 定时循环"；后续真正的 `Stop`（数组为空）或 `SessionEnd` 才落定。

**Blocked by:** None

**Status:** ready-for-agent

**Executor:** Claude · branch `claude/ai-04-stop-background-tasks` · 2026-09-23

- [ ] `HookParser` 解析并挂到 `HookEvent`（`backgroundTasks`、`sessionCrons`）。
- [ ] Reducer 规则 + 测试（夹具用官方文档形状）。
- [ ] 手机/Mac 行文案。
- [ ] 验收：一个 `/loop 1m` 会话在 Stop 后不响完成提醒。

## Comments

- 2026-09-23 规则修订（对照官方文档与同类项目后拍板，覆盖上面 What to build 的"非空即暂停"）：
  - 官方（code.claude.com/docs/en/hooks#stop-input）：`Stop` / `SubagentStop` 带 `background_tasks` 与 `session_crons`，用于区分"会话结束"与"暂停等后台工作"；两个数组只在 task registry 可达时出现，可能缺失。task 字段 `id`、`type`、`status`（未枚举）、`description`；cron 字段 `id`、`schedule`、`recurring`、`prompt`。
  - 同类做法：manaflow-ai/cmux（`hasActiveClaudeBackgroundWork`）、stablyai/orca（`claude-events.ts`，只在主 agent 的回合边界信 `background_tasks`，因为 teammate 空闲时也报 running）、rullerzhou-afk/clawd-on-desk（Stop gate + 去抖）、elirantutia/vibeyard（`HOOKS.md` "Stop resolution"：只有 subagent / teammate / workflow 保持 working，刻意忽略 `session_crons`，10 分钟兜底）。
  - **本票规则**：
    1. 只看主 agent 的事件（无 `agent_id`）。
    2. 有 `status` 为运行中的 `subagent` / `workflow` / `teammate` → 保持 working，不发完成提醒。
    3. 只有 `shell` / `monitor` / `MCP task` / `cloud session` 在跑 → 照常完成，行上显示"N 项后台任务"。
    4. `session_crons` 非空 → 这一轮照常落定为 done，但不发完成提醒，行上显示"已排定循环"，不转圈；否则 `/loop` 会话永远不会完成。
    5. 数组缺失或为空 → 回退到 SubagentStart / SubagentStop 计数；10 分钟兜底落定。
    6. `Stop` 之后才到的 `PostToolUse`（后台 Bash 的回执）不能把已完成的会话拉回 working（vibe-notch#98 的坑）。
  - 验收第 4 条保持："一个 `/loop 1m` 会话在 Stop 后不响完成提醒"，按规则 4 实现；另加一条：后台 subagent 跑完后的真正 `Stop` 正常提醒一次。
