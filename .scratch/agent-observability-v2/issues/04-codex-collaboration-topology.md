# 04: 显示 Codex collaboration 子任务进度

**What to build:** Codex Desktop 或 CLI 的 rollout/hook 提供 collaboration 记录时，VibeBuddy 使用已经验收的父子展示呈现活动子代理、最近工具和完成情况；信号不足时明确标为未知，不从项目名、进程数或时间间隔推断子任务。

**Blocked by:** 02: 显示观察来源与兼容性健康状态; 03: 显示 Claude 父会话与 teammate/subagent 进度.

**Status:** ready-for-agent

- [x] 已知 Codex collaboration spawn/send/wait/stop 记录能关联到正确父 task，并复用统一的子代理展示而不引入 Codex 专属 UI 分叉。
- [x] 并发子代理、等待其中任意一个、子代理失败、父 turn 先结束和 daemon 中途启动均有确定、可测试的归约结果。
- [x] rollout 未提供可靠子代理身份或完成信号时展示 unknown/degraded 来源，不制造虚假的 running 或 done。
- [ ] 仅用少量快速回归测试保护可靠身份、unknown/degraded 和父 turn 结束主路径；构建并运行实际 Mac app/daemon，以真实 Codex Desktop collaboration 会话核对快照和 Mac/iOS 展示。

## Implementation notes

Worktree from `e58c29c`. Reuses ticket 03 `AgentSession.childAgents` / `ChildAgent` / `ToolActivity.childSummary`. No Codex-specific UI.

### Reduction

- Desktop rollout `collaboration/spawn_agent` with `task_name` (args or output `/root/<name>`) starts `task:<name>`.
- `send_message` / `followup_task` with `target` upsert that child and set `lastActivity`.
- `interrupt_agent` with `target` completes that child.
- `CollabAgentToolCall` with non-empty `receiver_agents` completes those named children (`status=failed` is still an end). Empty `receiver_agents` is not an end signal (it also fires on wait timeout).
- `wait_agent` output `timed_out: true` does not change children. `timed_out: false` with no named receivers marks running children `unknown` and sets `childTopologyDegraded`.
- `list_agents` named `agent_status` is applied when present (`running` / `{completed:…}` / `interrupted`). `/root` is the parent and is not a child.
- Missing identity does not invent an id from project name, process count, or elapsed time.
- Parent `task_complete` does not complete children. Daemon bootstrap restores live running/unknown children even after the parent turn ended, plus the degraded flag.

### Tests / builds

- `swift test --filter CodexRolloutMonitorTests` **22/22**.
- `swift test --filter SessionReducerTests` **34/34**.
- Mac Debug `VibeBuddyMacApp` **BUILD SUCCEEDED** (`xcodegen generate` locally; xcodeproj not committed).

### E2E (isolated; did not bind 9876)

Isolated `./.build/debug/vibebuddyd` on **18766** with `VIBEBUDDY_TOKEN=ticket04-e2e`, journal `/tmp/vb04-journal.jsonl`. Read the live Codex Desktop rollout `01a05f96-1190-7af1-9681-67feb3189deb` (mtime within recovery window). Production `:9876` was not listening.

After daemon mid-start, snapshot:

- parent `论文_02_著作权法的身体预设_AI时代的暴露与重建` `done`, `childTopologyDegraded=true`
- `task:intro_test_review` and `task:intro_sketch_review` `unknown` (wait-any never named who finished)
- named completions from `list_agents` / `interrupt_agent` were not left running
- curl `127.0.0.1:18766/health` stayed `ok`; daemon then stopped; 18766 released

### Gaps (not forged)

- Did not launch a second Mac GUI against 18766 (same bundle id as the installed app). Topology was verified from the isolated snapshot the Mac/iOS rows consume.
- iOS Simulator was not launched against this isolated daemon.
- Did not drive a fresh Codex Desktop collaboration from this session. Concurrent spawn, wait-any, interrupt, and parent-turn-end were reduced from the existing live rollout plus unit tests.
- Observed `CollabAgentToolCall.wait` records had empty `receiver_agents` / `agents_states` and `status=completed` even on timeout. Named wait-any therefore depends on `receiver_agents` when Codex provides them; otherwise the result is unknown/degraded, not guessed running/done.
- No live `CollabAgentToolCall` with `status=failed` in recent rollouts; failure-with-identity is covered by the named-receiver reducer and `interrupt_agent`.
- Codex CLI rollout collaboration is still gated on desktop originator (`Codex Desktop` / `vscode`), same as ticket 01.
