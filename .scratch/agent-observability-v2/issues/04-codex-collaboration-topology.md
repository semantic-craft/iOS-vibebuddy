# 04: 显示 Codex collaboration 子任务进度

**What to build:** Codex Desktop 或 CLI 的 rollout/hook 提供 collaboration 记录时，VibeBuddy 使用已经验收的父子展示呈现活动子代理、最近工具和完成情况；信号不足时明确标为未知，不从项目名、进程数或时间间隔推断子任务。

**Blocked by:** 02: 显示观察来源与兼容性健康状态; 03: 显示 Claude 父会话与 teammate/subagent 进度.

**Status:** ready-for-agent

- [ ] 已知 Codex collaboration spawn/send/wait/stop 记录能关联到正确父 task，并复用统一的子代理展示而不引入 Codex 专属 UI 分叉。
- [ ] 并发子代理、等待其中任意一个、子代理失败、父 turn 先结束和 daemon 中途启动均有确定、可测试的归约结果。
- [ ] rollout 未提供可靠子代理身份或完成信号时展示 unknown/degraded 来源，不制造虚假的 running 或 done。
- [ ] 仅用少量快速回归测试保护可靠身份、unknown/degraded 和父 turn 结束主路径；构建并运行实际 Mac app/daemon，以真实 Codex Desktop collaboration 会话核对快照和 Mac/iOS 展示。
