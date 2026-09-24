# 09: 手表横幅「回复」直接打开 App，不收文字

**What to build:** 让手表横幅上的「回复」要么真能口述，要么如实改成「打开回答」。定方案前先查 Apple 文档和同类 App：watchOS 上带 `.foreground` 的 `UNTextInputNotificationAction`，在镜像通知里会不会先弹输入框。

**Status:** needs-triage

## 为什么

2026-09-24 腕上验收（watchOS 27，Series 10，开发版 1.3.28 (58)）：三次点横幅「回复」（11:26、11:28、11:29），推送后 5–10 s 手表诊断都记为 `notification.action-opens`（回答动作，但 `userText` 为空，所以按 `.open` 处理），看到的是 App 自己的卡片（Yes / No / 口述），没有系统输入框。结果什么都没发出去，是安全的。但 WR-07 / ADR-0033 决定 5 的「横幅口述」路径在这块表上走不到，WR-07 票里 owner 步骤的第 1–4 步都依赖横幅口述，全都走不到。排查时先分清 `userText` 是 nil（响应根本不是 `UNTextInputNotificationResponse`）还是空字符串。

## 待定

- 手机的类别和手表共用：`.foreground` 是 ADR-0033 为了让点击在手表上执行而加的，去掉它会把点击送回口袋里的手机。
- 可能的方向：按钮改名、卡片打开后直接进入口述、或按平台分别注册类别。需要对照 Apple 文档实测后再选。
