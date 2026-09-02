# 03: 显示 Claude 父会话与 teammate/subagent 进度

**What to build:** Claude 会话卡片显示其活动 teammate/subagent 的数量、名称或类型、当前活动和完成状态，让用户能区分父会话正在工作、等待子代理以及子代理已经结束，而不是只看到一个普通的 “Subagent” 工具标签。

**Blocked by:** 02: 显示观察来源与兼容性健康状态.

**Status:** ready-for-agent

- [ ] Claude 的子代理/任务事件以稳定身份关联到正确父会话，重复、乱序和缺失的 start/stop 事件不会产生幽灵子代理。
- [ ] Mac 与 iOS 会话展示至少包含活动子代理数量、可用的名称/类型和最近活动；父会话三态仍由父级语义事件决定。
- [ ] teammate idle、任务完成、会话结束和 daemon 恢复后，子代理状态能够正确结束或恢复，不遗留永久运行标记。
- [ ] 仅用少量快速回归测试保护父子关联和结束归约主路径；构建并运行实际 Mac app/daemon，以真实 Claude 单个及并发子代理会话核对快照和 Mac/iOS 展示。
