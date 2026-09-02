# 07: 增加隔离的 Codex 用量与配额适配器

**What to build:** 用户可以在不影响开发进度监控的前提下查看 Codex 当前用量、配额窗口和下一次重置；用量采集是独立、可关闭的数据源，认证或刷新失败不会修改 working/needs-response/done。

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Codex 用量展示包含数据更新时间、已知窗口/重置时间和不可用原因，并与会话进度状态在模型和界面上明确分离。
- [ ] 刷新采用有界超时、缓存和退避；离线、未登录、格式变化或限流时保留最后可信值并标记过期，不生成虚假零值。
- [ ] 用户能够关闭用量采集，关闭后不启动相关网络/CLI 工作且会话监控、通知和 Codex Desktop rollout 继续正常。
- [ ] 仅用少量快速回归测试保护官方数据解析、last-known-good/stale 和错误隔离主路径；构建并运行实际 Mac app，以当前 Codex 账户完成只读刷新、禁用和 UI/告警端到端验收且不记录凭据。
