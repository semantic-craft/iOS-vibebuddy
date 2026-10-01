# GROK-03：自动显示已运行的 Grok 会话

Status: ready-for-agent
Priority: P1
Date: 2026-10-02
Parent: GROK-01
Blocked by: GROK-02 — Grok Build 一键接入与状态反馈

## What to build

开启监控后发现已经运行的 Grok 会话，在面板显示项目与“已发现，等待接入”。将必要的重载操作放在卡片上，收到真实事件后更新同一张卡片；界面、快照与 WebSocket 一致。

## Acceptance criteria

- [ ] 无 hooks 的真实活跃 Grok 会话在一次正常发现周期内可见，不要求发新提示。
- [ ] 发现不伪造 working/done、完成通知、权限请求或控制能力；等待接入时给明确下一步。
- [ ] 后续事件更新同一会话，不重复或覆盖真实状态，不重复接管 ACP 托管会话。
- [ ] 检查 PID 与存活状态，保持 leader 下的退出语义；不把历史会话当作活跃会话。
- [ ] 关闭监控后已发现卡片退出实时状态，并保留历史事实；重新开启能恢复发现。
- [ ] 用真实 Grok 数据核对 UI、快照和 WebSocket；保留原始缺失场景的可重放回归检查，更新接入文档。
