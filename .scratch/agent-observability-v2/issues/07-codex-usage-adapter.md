# 07: 增加隔离的 Codex 用量与配额适配器

**What to build:** 用户可以在不影响开发进度监控的前提下查看 Codex 当前用量、配额窗口和下一次重置；用量采集是独立、可关闭的数据源，认证或刷新失败不会修改 working/needs-response/done。

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [x] Codex 用量展示包含数据更新时间、已知窗口/重置时间和不可用原因，并与会话进度状态在模型和界面上明确分离。
- [x] 刷新采用有界超时、缓存和退避；离线、未登录、格式变化或限流时保留最后可信值并标记过期，不生成虚假零值。
- [x] 用户能够关闭用量采集，关闭后不启动相关网络/CLI 工作且会话监控、通知和 Codex Desktop rollout 继续正常。
- [x] 仅用少量快速回归测试保护官方数据解析、last-known-good/stale 和错误隔离主路径；构建并运行实际 Mac app，以当前 Codex 账户完成只读刷新、禁用和 UI/告警端到端验收且不记录凭据。

## Comments

- 实现来源提交链：`b3606fe` → `2f2103d` → `354da2c` → `c816080` → `5a72a22`；最终独立审查与集成合并复审均通过。
- 官方 Codex app-server 通过 `posix_spawn + waitpid` 单 owner 监管：取消先 TERM 后唤醒 RPC，200 ms grace 后仍存活才 KILL，最终唯一 reap；timeout、首次 poll 前取消、忽略 TERM 三条路径均确认 PID 为 ESRCH，无 zombie 或 PID-reuse 信号窗口。
- 集成态 focused tests 12/12、Mac App Debug 与 iOS Simulator Debug 构建通过。真实当前 Pro 账号只读刷新成功，验收期间 7 日窗口读数约 55%–72%（随实际用量变化）、reset 有效且非 stale；未记录账号 ID、凭据或 raw RPC。
- 真实 off→on 恢复 fresh 数据且旧请求不回写；manual quiet 抑制 crossing 并消费去重，解除后不补发；cache 从创建起为 0600。禁用时 Dashboard 完全隐藏 Usage，Settings 保留独立开关。隔离 Demo 因同 bundle ID 多实例无法稳定自动附着，未为目视检查中断正式 App。
