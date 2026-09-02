# 08: 在同一用量接口接入 Claude 配额

**What to build:** Claude 与 Codex 使用一致的用量展示、刷新和告警语义，但各自独立采集和失败隔离；用户可以单独关闭 Claude 用量，而不影响 Claude hooks、会话进度或 Codex 用量。

**Blocked by:** 07: 增加隔离的 Codex 用量与配额适配器.

**Status:** ready-for-human

- [x] Claude 用量通过 07 建立的统一接口显示更新时间、窗口/重置信息、过期状态和不可用原因，不复制第二套 UI 或缓存策略。
- [x] Claude 认证、限流、格式变化或采集失败只降低 Claude 用量来源，不影响 Claude/Codex 会话进度及 Codex 用量。
- [x] Claude 与 Codex 可分别启用，统一预算提醒能标明提供方并遵守现有安静模式与防重复规则。
- [x] 仅用少量快速回归测试保护双提供方隔离、单方失败、禁用和缓存过期主路径；构建并运行实际 Mac app，以当前 Claude 账户完成只读刷新和统一 UI/告警端到端验收且不记录凭据。

## Implementation notes

- 原始实现提交链：`46f4ab0` → `55b4e7b` → `7f8473b`。独立审查先指出进程组回收、百分比边界和快速开关竞态，修复后复审通过。
- Claude 只读采集使用官方 `/usage` CLI 输出；Claude 与 Codex 共用 `AccountUsage` 模型、缓存和展示语义，但 collector、启用开关、错误与刷新任务彼此隔离。
- `POSIXCommandSupervisor` 由单一 worker 持有子进程回收，覆盖超时、取消、进程组 TERM/KILL、非阻塞 stdout/stderr 排空及 1 MiB 上限；root 以 WNOWAIT 保留时会无条件清理进程组，测试包含关闭 stdio 且忽略 TERM 的后代，不能再用 pipe EOF 误判进程组为空。禁用会先使 collector generation 失效，再等待旧 UI 任务结束。
- 缓存最终内存提交与原子 rename 都绑定 generation permit；测试用 gate 证明已开始的旧保存不能跨越 disable/enable 提交。
- 验证：`swift test --filter AccountUsageTests` 17/17；源 worktree 完整 SwiftPM 267/267（33 suites）；集成工作树 Mac Debug 构建（同时修正 Xcode 工程对改名后 `UsageView.swift` 的引用）；实际 Claude 账户快速 off/on 后读到新鲜 10%/15% 窗口。正式已安装 App 与 9876 端口未被中断。
- 本工单没有声明真实阈值通知已被人工触发；通知防重复、安静模式和 provider 标识由测试覆盖，真实通知交付健康属于 06。
