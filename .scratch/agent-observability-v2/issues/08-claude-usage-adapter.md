# 08: 在同一用量接口接入 Claude 配额

**What to build:** Claude 与 Codex 使用一致的用量展示、刷新和告警语义，但各自独立采集和失败隔离；用户可以单独关闭 Claude 用量，而不影响 Claude hooks、会话进度或 Codex 用量。

**Blocked by:** 07: 增加隔离的 Codex 用量与配额适配器.

**Status:** ready-for-agent

- [ ] Claude 用量通过 07 建立的统一接口显示更新时间、窗口/重置信息、过期状态和不可用原因，不复制第二套 UI 或缓存策略。
- [ ] Claude 认证、限流、格式变化或采集失败只降低 Claude 用量来源，不影响 Claude/Codex 会话进度及 Codex 用量。
- [ ] Claude 与 Codex 可分别启用，统一预算提醒能标明提供方并遵守现有安静模式与防重复规则。
- [ ] 仅用少量快速回归测试保护双提供方隔离、单方失败、禁用和缓存过期主路径；构建并运行实际 Mac app，以当前 Claude 账户完成只读刷新和统一 UI/告警端到端验收且不记录凭据。
