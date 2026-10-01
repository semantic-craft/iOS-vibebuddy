# 02: 能力识别与只读任务目标

Status: ready-for-agent

**What to build:** 能力识别与只读任务目标，作为本期 iOS 与 macOS 配套工作的完整用户路径。

**Blocked by:** None (can start immediately).

- [ ] 手机能发现所连 Mac 的读取能力；旧 Mac 明确显示不支持，不误报网络断开。
- [ ] 同一条端到端路径提供只读 Codex 目标、预算、来源、时间及不可用状态。
- [ ] 接口按配对鉴权及 sourceID/sessionID 约束，不恢复或启动线程，不确认已读，不增加控制权限。
- [ ] 切换 Mac/任务、断线及过期请求不得串数据；共享 Kit 定义稳定 Codable 契约。
