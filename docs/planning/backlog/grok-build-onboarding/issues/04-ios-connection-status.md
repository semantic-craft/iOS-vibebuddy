# GROK-04 — iOS Grok Build 接入状态与发现卡片

Status: ready-for-agent

## 问题
Mac 已广播 grokMonitoring，但 iOS 没有承接；尚未接入的 Grok 在手机端仍不可见。

## 实施与验收
- 收件箱显示 Grok Build 接入状态和已发现项目，即使没有正式 AgentSession；agent strip 可选 Grok，发现记录不计入任务数量。
- 展示未开启、未安装、配置异常及原因、等待接入、已连接状态；给出在 Mac 的 VibeBuddy 设置中开启/重试以及 Grok `/hooks` → `r` 的指引。手机不提供无效的远程安装按钮。
- 根据 agent 选择过滤；出现真实会话后沿用原任务列表，发现卡片随快照消失，不产生重复任务、完成通知或操作权限。
- 老 Mac 缺失字段时保持原体验；断线标明上次状态，切换 Mac、忘记配对或进入 Demo 不残留旧状态。
- 中英文文案、VoiceOver、动态字体使用现有设计规范。
- 运行 iOS 构建和相关回归检查，在隔离模拟器验证真实 daemon 数据与界面；区分模拟器、真机和安装版验证。

## 边界
只改 iOS 状态承接；复用现有共享协议与 Mac 接入，不扩展 Watch、通知、远程安装或 Grok Bot。保留当前工作区其他未提交改动。
