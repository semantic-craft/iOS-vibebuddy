# 04: Claude `Stop` 带后台任务或定时循环时不进 done

**What to build:** `HookParser` 读 `Stop` 的 `background_tasks[]`（type ∈ shell/subagent/monitor/workflow/teammate/cloud session/MCP task）与 `session_crons[]`；非空时该 `Stop` 视为"暂停等后台工作"：会话保持 working（或新状态语义按 CONTEXT 决定），完成提醒不发，行上显示"N 项后台工作 / 定时循环"；后续真正的 `Stop`（数组为空）或 `SessionEnd` 才落定。

**Blocked by:** None

**Status:** done（#264 已合并；2026-09-24 真实会话验收通过，见 Comments 末条）。保留作验收记录，不按完成即删的惯例删除。

**Executor:** Claude · branch `claude/ai-04-stop-background-tasks` · 2026-09-23

- [x] `HookParser` 解析并挂到 `HookEvent`（`backgroundTasks`、`sessionCrons`）。
- [x] Reducer 规则 + 测试（夹具用官方文档形状）。
- [x] 手机/Mac 行文案。
- [x] 验收：一个 `/loop 1m` 会话在 Stop 后不响完成提醒。

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
- 2026-09-23 实现与评审修订（Opus 评审 PR #264 后）：
  - 规则 5 改为：**数组存在（即使为空）以数组为准**；只有数组缺失（旧版 CLI 或 registry 不可达）才用子代理计数。原因：残留的子代理行（async hook 丢了 `SubagentStop`、Esc 打断前台子代理）会让之后每一轮都挂 10 分钟。主 agent 的 Interrupt / StopFailure / 用户停止会把仍在跑的子代理标为 unknown。
  - 只被 subagent 挂起的轮次：收到与挂起时数量相同的 `SubagentStop` 且没有仍在跑的子代理后，进入 45 秒宽限；主 agent 通常在宽限内续跑，它自己的 `Stop` 取代挂起的那个，所以只提醒一次、用的是新文案。workflow / teammate 没有结束 hook，只能由更新的 `Stop` 或 10 分钟兜底释放。
  - 释放出的 `Stop` 用释放时刻作时间戳，避免完成提醒立刻叠加。
  - daemon 重启后恢复为 working 的 Claude 会话，10 分钟无事件则安静落定（`probeRetired`）。
  - 规则 4 只认 `recurring` 的 cron；一次性提醒不让之后每轮都静音。
  - 已知取舍：规则 3 的"还有 N 项后台任务"在 done 之后没有递减事件，只有 Claude 续跑发出新的 `Stop` 时更新；旧版 iPhone 前台连着时仍会为每轮 loop 响一次（新 `SoundPolicy` 随新版手机生效）。

- 2026-09-24 真实会话验收（Claude Code 2.1.280 / 2.1.281，Sonnet 5，claude.ai Max OAuth；干净环境、tmux 里的交互会话；每个会话另挂一个 `--settings` 抓原始 hook 载荷。证据在 `~/Projects/_shared-work/iOS-vibebuddy/ai04-acceptance-2026-09-23/`：`记录表.md`，`dryrun/`、`run1-headless/`、`run2-shared/`）：
  - **真实字段**：
    - 子代理：`{"id","type":"subagent","status":"running","description","agent_type":"general-purpose"}`。
    - 后台 shell：`{"id","type":"shell","status":"running","description","command"}`。子代理用 Monitor 起的等待任务也报 `shell`（TUI 显示为「1 shell, 1 monitor」）。
    - `session_crons`：`{"id","schedule":"*/1 * * * *","recurring":true,"prompt"}`。
    - 只见过 `status:"running"`：任务结束后直接从数组消失，没有出现结束态字符串。每个主 agent 的 `Stop` 都带这两个数组，没有任务时为 `[]`（`claude -p` 也一样）。
  - **/loop 1m：通过**。第 1 轮用隔离 `vibebuddyd`（:9877，02:17–02:19）；第 2 轮用共享菜单栏 App（:9876，main `d43c762b`，PID 86865，09:21:31 / 09:22:19 / 09:23:19 / 09:24:24），共 7 轮。每一轮都落定为 `done` + `loopScheduled: true`，没有未读，也没有完成标识。共享 App 的投递日志里，这个会话 0 条记录，而且它当时因为刚输入过提示词是自动「已关注」（完成本应横幅加声），仍然没响。
  - **后台 subagent：通过**。09:37:55 发出；09:38:02 的 `Stop` 带一个 running 的 subagent，会话保持 `working`（`backgroundTaskCount 1`）；09:40:03 收到 `SubagentStop`；09:40:03 与 09:40:04 连续两个空数组的 `Stop`，只生成一个完成标识。09:40:09 投递日志记下 Mac 本机通知 1 条、APNs 2 条（已登记的两台 iPhone 各 1 条，均 accepted），之后 2 分钟内没有第二条。第 1 轮无界面 daemon 上的状态变化也一样（02:19:48 挂起，02:21:39 落定，一个完成标识）。
  - **发现**：
    - `vibebuddyd` 只推「需要你回应」和已关注会话的完成重提醒，第一次完成提醒（agentDone）由菜单栏 App 发（`MenuBarModel` 的 `PushFanout`）。所以隔离 daemon 只能验证状态，「响没响」要走菜单栏 App。
    - 一次结束常带两个相隔约 1 s 的 `Stop`（同一条最后回复），第二个没有生成新标识，行为正确。
    - 多数轮次有 1 条或以上没有对应 `SubagentStart` 的 `SubagentStop`（CLI 内部代理，`agent_type` 为空；第 2 轮每次 `Stop` 后约 1 s 出现一条，后台子代理那轮有 4 条）。它们会先把挂起 `Stop` 的 `awaitedSubagentStops` 扣到 0，目前靠「仍有 running 子代理」这条检查兜住，没有提前放行；但如果真正子代理的 `SubagentStart` 丢了，这条检查兜不住，会提前进入 45 s 宽限（可改为只对已知 running 子代理的 `SubagentStop` 扣减）。
    - 输入提示词会让会话自动「已关注」10 分钟。未读的完成会在 +5 分钟重提醒（09:30:14 一个中途作废的测试会话就收到了一次），这是设计行为，不是重复提醒。
    - 与产品无关的测试坑：2.1.281 的 Bash 会拦截单独前台运行的 `sleep N`（改用 `python3 -c "import time; time.sleep(90)"`）；`/loop 1m … Do not call any tools.` 在 2.1.281 上有一次连 `CronCreate` 都没调用。
  - **没覆盖**：手机 App 在前台时自己的 `SoundPolicy`。Hermes 上的 1.3.28 (58) 开发版早于 #264，本轮手机只接收 Mac 发来的 APNs。
