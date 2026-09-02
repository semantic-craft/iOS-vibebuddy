# 01: Codex Desktop 改为事件驱动监控

**What to build:** Codex Desktop 的 rollout 文件发生变化后，VibeBuddy 立即更新对应会话；文件事件负责实时进度，短去抖负责合并突发写入，低频扫描只负责发现新会话和失联恢复，不再依赖持续的一秒轮询。

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [x] 已跟踪 rollout 的追加内容在一秒内贯通到 Mac 快照和现有通知状态机，连续写入不会产生重复或乱序状态转换。
- [x] 新 rollout、文件截断/替换、跨日目录、daemon 重启和 watcher 失效均能由有界的发现/恢复机制自愈。
- [x] watcher 健康时不再执行持续的一秒目录扫描，取消监控或会话结束后文件描述符与任务都会释放。
- [x] 仅用少量快速回归测试保护去抖、增量 cursor 和恢复主路径；构建并运行实际 Mac app/daemon，以真实 Codex Desktop 会话完成一次 working → needs-response/done 端到端验收。

## Comments

- 实现来源提交链：`7dab11a` → `5f479a7` → `cca8159`；第三轮独立审查通过，确认单 FIFO 投递、server/monitor 结构化生命周期，以及 recovery actor 重入竞态已关闭。
- 集成态 `CodexRolloutMonitorTests` 18/18 通过；确定性回归会在 recovery 已进入、scan 前挂起时取消 monitor，并确认最终 watcher、recovery、delivery、debounce 与 queue 均归零。
- 集成态 Mac App Debug 构建成功。真实独立 daemon 读取当前 Codex Desktop rollout，运行时 11 个 watcher FD；Ctrl-C 后进程、端口和 rollout FD 均释放。真实追加到快照约 74 ms，并完成 working → done 验收；原安装版 App 已恢复且 `/health` 正常。
