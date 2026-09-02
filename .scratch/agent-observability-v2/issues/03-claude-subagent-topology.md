# 03: 显示 Claude 父会话与 teammate/subagent 进度

**What to build:** Claude 会话卡片显示其活动 teammate/subagent 的数量、名称或类型、当前活动和完成状态，让用户能区分父会话正在工作、等待子代理以及子代理已经结束，而不是只看到一个普通的 “Subagent” 工具标签。

**Blocked by:** 02: 显示观察来源与兼容性健康状态.

**Status:** ready-for-agent

- [x] Claude 的子代理/任务事件以稳定身份关联到正确父会话，重复、乱序和缺失的 start/stop 事件不会产生幽灵子代理。
- [x] Mac 与 iOS 会话展示至少包含活动子代理数量、可用的名称/类型和最近活动；父会话三态仍由父级语义事件决定。
- [x] teammate idle、任务完成、会话结束和 daemon 恢复后，子代理状态能够正确结束或恢复，不遗留永久运行标记。
- [ ] 仅用少量快速回归测试保护父子关联和结束归约主路径；构建并运行实际 Mac app/daemon，以真实 Claude 单个及并发子代理会话核对快照和 Mac/iOS 展示。

## Implementation notes

Local worktree commit pending independent review. Do not treat this as `ready-for-human` until that review PASSes.

### Reduction

- `SubagentStart` / `SubagentStop` / `TaskCreated` / `TaskCompleted` / `TeammateIdle` are `HookEvent.Kind.childLifecycle`, not parent `preToolUse`/`postToolUse`.
- Stable ids: `subagent:<agent_id>`, `task:<task_id>`, `teammate:<team>/<name>`. Missing identity sets `childTopologyDegraded` and does not invent an id from project name, process count, or time.
- Duplicate starts upsert one child. Stop without start records `completed`, never `running`. Stale out-of-order events (`timestamp` older than the child's `updatedAt`) are ignored.
- Nested `PreToolUse`/`PostToolUse` with `agent_id` update that child's `lastActivity` only; they do not move parent status, `waitKind`, or `activeTool`.
- `restore()` still uses the existing journal and always clears `childAgents` / `childTopologyDegraded` until a new live start.

### Tests / builds

- `VibeBuddyMac`: `swift test --filter SubagentTopologyTests` / `HookParserTests` / `SessionReducerTests`; full `swift test` **284/284**.
- `VibeBuddyKit`: `swift test --filter ToolActivityTests` **5/5**.
- Mac Debug `VibeBuddyMacApp` and iOS Simulator Debug `VibeBuddyApp` **BUILD SUCCEEDED**.

### E2E (isolated; production `:9876` left running)

Isolated `vibebuddyd` on **18765** with `VIBEBUDDY_TOKEN=ticket03-e2e`, dummy APNs env so pusher stayed off, journal `/tmp/vb03-journal.jsonl`. Real `claude -p` in `/tmp/vb03-e2e` inherited `VIBEBUDDY_PORT`/`VIBEBUDDY_TOKEN`.

- Single Explore: parent `vb03-e2e` `working` → child `Explore` `running` → `completed` → parent `done` → `SessionEnd` dropped the row.
- Concurrent Explore: two ids `subagent:a78580ea4da051181` and `subagent:a6c17140ffcf1ee81` both `running`, then one completed while the other still ran, then both `completed`. Parent `activeTool` was `Agent` (parent spawn tool), not a flattened `Subagent: Explore` label. `curl 127.0.0.1:9876/health` stayed `ok`.

### Gaps (not forged)

- Installed Claude hooks do **not** include `TeammateIdle` (parser/reducer cover it; no live idle hook was forwarded).
- Did not launch a second Mac GUI instance against 18765 (same bundle id as the installed app on 9876). Live topology was verified from the isolated snapshot the Mac/iOS rows consume; Mac/iOS session rows render `ToolActivity.childSummary`.
- iOS Simulator Debug launched with `VIBEBUDDY_DEMO=1` and showed the demo dashboard, but the first-run notification permission alert covered the thinking rows, so the child line was not visually confirmed on device.
- Daemon-restart restore of child topology was covered by unit tests (`restore()` strips children), not a second live Claude after killing 18765.
