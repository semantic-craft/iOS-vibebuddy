# SET-02：通用设置可被准确操作

Status: ready-for-agent
Blocked by: None（可立即开始）
Parent: [SET-01](01-settings-ux-dx-ax.md)

## What to build

通用设置的开关和快捷键可以通过明确名称操作，应用语言沿用现有实现。

## Acceptance criteria

- [ ] 开机启动、菜单栏、Glance 的开关有名称、稳定标识及当前值；禁用原因可理解。
- [ ] 三个快捷键录制按钮有独立对象名称；录制与取消保留原有行为和存储键。
- [ ] 已有语言设置不重复实现；验证中英文、最小支持窗口、键盘焦点和偏好保留。

## Boundaries

保留既有未提交工作；不变更真实凭据、生产安装、连接协议或既有默认行为。每票包含适用构建、Computer Use 和回归验证，记录已验证与未验证状态。所有UI修改同时评估UX、DX、AX，优先复用现有组件，不引入设置框架。
