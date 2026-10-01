# 06: iOS 设备端最终验收

Status: ready-for-human

第一、二批实现及双轴评审已完成；可用验证见 [acceptance.md](../acceptance.md)。
原 01–05 已实现并按仓库约定移除工单，本工单保留尚未实际完成的设备体验验收。

- [x] 共享库、Mac 核心全套测试，Mac / iOS 构建与 iOS 模拟器测试。
- [x] 隔离 daemon 使用真实 Codex 会话数据，鉴权、来源边界与本地历史读取。
- [x] Standards / Spec 分别评审，修复暂停恢复与终端分页覆盖问题。
- [x] 原生模拟器 UI E2E：中文朗读设置、独立语言选择、密钥编辑取消、真实历史回退与最大字号操作可达；截图核验。
- [x] 真实 MiniMax 四种风格合成并进入 iOS 原生播放器；最终音频 / 网络定向复验 12/12，UI E2E 2/2。
- [ ] 在 iPhone 安全输入本机 MiniMax 密钥，试听各风格，耳听核对音色；检查来电、耳机拔出和 VoiceOver 共存。自动化回归不代替耳听与实物音频路由。
- [ ] 在拥有真实目标及后台终端的 Codex app-server 上核验目标数值与多页终端；本轮隔离 app-server 未持有原线程运行时及完整原生项目索引。

不包含发布、替换 /Applications 或生产 token。当前实现保留旧 Mac 的明确降级。
