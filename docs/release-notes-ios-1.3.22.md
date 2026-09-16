# VibeBuddy 1.3.22 for iPhone and Apple Watch

## 简体中文

- 任务详情与 Recap 使用全屏页面，便于阅读完成结果和返回任务列表。
- 在手机查看任务对话历史，并区分当前轮次的完成正文和旧通知。
- 通知设置显示系统授权状态，语音与模型设置提供更清晰的反馈和帮助。
- 同名项目显示可区分的父路径，长路径更易查看。
- 扫码配对先验证 Mac 实时连接，失败或取消时保留原配对。
- 修复任务详情中的审批及问答提示文字重叠。

## English

- Read task details and Recap in full-screen pages, with clear navigation back to your tasks.
- Browse task conversation history and distinguish the current completion from older notifications.
- See system notification permission status and clearer feedback and help in voice and model settings.
- Distinguish projects with the same name using their parent paths.
- Verify a scanned Mac connection before replacing your saved pairing. Failed or cancelled checks keep the existing connection.
- Fix overlapping approval and question content in task details.

## Release evidence

Phone, Watch and widget build numbers are aligned at 1.3.22 (50). The Release archive and production-signed device export were verified; build 50 was installed on the physical iPhone and reconnected using its saved pairing.

Physical acceptance covered an interrupted network followed by automatic recovery, one real Claude command approved from the phone with an explicit hook receipt and actual output, and an unavailable manually entered pairing candidate that preserved the saved connection. The last two flows were exercised on build 49 before the two fixes were installed. The scanner fix passed independent review and the shared connection checks passed 8 tests with 1 opt-in live-daemon test skipped. Camera scanning itself was not exercised through iPhone Mirroring.

The companion Mac idle-reminder fix preserves the completed result and unread state. It has 72 relevant passing tests and local runtime acceptance. It is not included in the existing public Mac build 36 artifact.

App Store upload, review submission, approval and availability are separate states. This document does not assert approval or availability.
