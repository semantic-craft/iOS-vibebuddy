# 02: 显示观察来源与兼容性健康状态

**What to build:** 用户可以看出每个会话由 hook、rollout、transcript 或恢复观察中的哪一种信号支撑，并在设置中看到 Claude/Codex 的最后信号时间、事件覆盖和明确的健康/降级原因；需要修复时由用户主动执行安全、可逆的修复。

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] 会话快照携带稳定的观察来源身份、最后观察时间和健康状态，Mac 与 iOS 对同一状态使用一致的人类可读说明。
- [ ] 健康检查能区分未安装、事件缺失、Codex async 不兼容、rollout 不可读、暂时静默和正常运行，不以进程存在猜测 working/needs-response。
- [ ] 设置界面展示 Claude 与 Codex 各自的诊断结果，并且只有在用户明确操作后才运行幂等、可逆的 hook 修复。
- [ ] 仅用少量快速回归测试保护来源组合、变旧恢复和诊断隔离；构建并运行实际 Mac app/daemon，核对真实 Claude/Codex 健康、降级说明与用户 hook 保留，且诊断失败不得改变现有会话进度。
