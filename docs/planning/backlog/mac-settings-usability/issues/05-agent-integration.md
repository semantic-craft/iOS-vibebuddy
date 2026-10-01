# SET-05：Agent接入MCP与诊断各自清楚

Status: ready-for-agent
Blocked by: None（可立即开始）
Parent: [SET-01](01-settings-ux-dx-ax.md)

## What to build

用户能区分监控接入与 MCP 工具，找到 Cursor 云端任务配置，并理解状态影响。

## Acceptance criteria

- [ ] 侧栏和相关文档准确区分手机连接、Agent接入、Agent工具（MCP），保留页面身份和命令契约。
- [ ] Cursor云端任务凭据入口迁至Agent接入，复用既有配置和存储，不扩大授权。
- [ ] 权限与沙盒不以原始JSON作为主要说明；未知仍标未知，原值可查看。
- [ ] 诊断区分来源不可用与整体监控，修复按钮带对象和范围；用真实Agent数据核对解释，不擅自修复生产配置。
- [ ] 控件语义、中英文、键盘和最小窗口验收；不改监控判定、daemon或MCP协议。

## Boundaries

保留既有未提交工作；不变更真实凭据、生产安装、连接协议或既有默认行为。每票包含适用构建、Computer Use 和回归验证，记录已验证与未验证状态。所有UI修改同时评估UX、DX、AX，优先复用现有组件，不引入设置框架。
