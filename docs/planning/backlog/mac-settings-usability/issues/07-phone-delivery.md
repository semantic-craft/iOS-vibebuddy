# SET-07：手机连接页准确呈现连接与投递状态

Status: ready-for-agent
Blocked by: None（可立即开始）
Parent: [SET-01](01-settings-ux-dx-ax.md)

## What to build

手机页集中解释手机连接和通知投递，保留准确失败信息及诊断入口。

## Acceptance criteria

- [ ] 通知与投递区域不混入无关Agent监控故障；这些故障仍能在原有Agent/诊断入口找到。
- [ ] 配对保存、地址接收、连通检查、服务接受、设备实际显示不混为成功。
- [ ] 复用现有LAN/远程/Cloudflare工作，保持手机协议及ADR-0025边界；不改他人连接实现。
- [ ] 独立GUI验证中英文、AX、键盘与最小窗口；真机/权限不可用时写明缺口，不冒充验收。

## Boundaries

保留既有未提交工作；不变更真实凭据、生产安装、连接协议或既有默认行为。每票包含适用构建、Computer Use 和回归验证，记录已验证与未验证状态。所有UI修改同时评估UX、DX、AX，优先复用现有组件，不引入设置框架。
