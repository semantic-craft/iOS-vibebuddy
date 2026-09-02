# 02: 显示观察来源与兼容性健康状态

**What to build:** 用户可以看出每个会话由 hook、rollout、transcript 或恢复观察中的哪一种信号支撑，并在设置中看到 Claude/Codex 的最后信号时间、事件覆盖和明确的健康/降级原因；需要修复时由用户主动执行安全、可逆的修复。

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [x] 会话快照携带稳定的观察来源身份、最后观察时间和健康状态，Mac 与 iOS 对同一状态使用一致的人类可读说明。
- [x] 健康检查能区分未安装、事件缺失、Codex async 不兼容、rollout 不可读、暂时静默和正常运行，不以进程存在猜测 working/needs-response。
- [x] 设置界面展示 Claude 与 Codex 各自的诊断结果，并且只有在用户明确操作后才运行幂等、可逆的 hook 修复。
- [x] 仅用少量快速回归测试保护来源组合、变旧恢复和诊断隔离；构建并运行实际 Mac app/daemon，核对真实 Claude/Codex 健康、降级说明与用户 hook 保留，且诊断失败不得改变现有会话进度。

## Comments

- 实现来源提交链：`9a6a5af` → `3aa027d`；第二轮独立审查通过。修复后只有真实 runtime signal 或明确支持的 `0.151.x` 事件能标记 rollout healthy；metadata-only、future/无效 schema、目录不可读分别诚实降级。
- 集成态 Observation 测试 Mac 10/10、Kit 4/4 通过；hook installer 验证 7 个 CLI 的幂等安装、干净卸载与用户 hook 保留。Mac App 与 iOS Simulator Debug 构建均成功。
- 隔离 daemon `/health = ok`；真实 Claude hook/transcript 与当前 `0.151.0-alpha.7.2` rollout 为 healthy，未配置的 Codex hook 为 eventsMissing。诊断失败不改变既有三态；新鲜 signal 会在内存中即时恢复 stale 行，不触发每事件静态 IO。
- 新构建 Mac App 已实际启动；同 bundle ID 的安装版正在运行，因此未关闭或替换正式 App 来强行附着第二个 Settings 窗口。该边界不影响后端真实链路、共享 UI 模型或双端构建证据。
