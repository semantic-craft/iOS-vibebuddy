# 06: 整体验收与双轴评审

Status: ready-for-agent

**What to build:** 整体验收与双轴评审，作为本期 iOS 与 macOS 配套工作的完整用户路径。

**Blocked by:** 01, 02, 03, 04, 05.

- [ ] 在隔离服务与 iOS 模拟器上运行，使用真实 Codex/Claude 数据检查所改读取路径。
- [ ] 按影响范围做针对性测试、最终全套检查和 Mac/iOS 构建；只在真实边界保留高价值回归。
- [ ] 按 implement / code-review 做 Standards 与 Spec 独立评审并修复有效发现。
- [ ] 记录设备、真实凭据、VoiceOver 耳测等未能实际完成的边界，不能用 fixture 宣称通过；不替换生产 app 或发布。
