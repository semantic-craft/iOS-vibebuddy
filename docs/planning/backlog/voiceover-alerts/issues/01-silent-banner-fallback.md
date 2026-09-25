# 01: 开着 VoiceOver 时，看不见的系统通知不能算"已送达"

**Status:** done（本 PR；随 Mac 1.3.35 发布，不单独发版）。真机 VoiceOver 没听过，见「没验证的」。

**Blocked by:** None

## 问题

Mac 1.3.34 发布评审（PR #317）发现。G-4（#315）让 VoiceOver 开着时提醒改走系统通知，因为 VoiceOver 会读横幅，而刘海下的卡片不会被读。但路由只在通知**发送失败**时才退回卡片，而"发送成功"不等于"横幅出现了"：

- 用户把 VibeBuddy 的提醒样式设成「无」，或关掉了提醒：通知只进通知中心；
- 临时授权（provisional）：Apple 文档写明这类通知安静送达，不弹横幅、不响，只进通知中心的历史；
- 专注模式挡住了横幅。

这几种情况下横幅不出现、卡片被跳过，VoiceOver 什么都不读，用户不知道有 agent 在等。

## 修法

- 路由逻辑从 App 挪到 `VibeBuddyMacCore`（`AttentionRouting`），App 里的 `GlanceAttentionRouter` 只提供通知中心、刘海卡片、VoiceOver 三个出口。
- 开着 VoiceOver 时，先按当前通知设置判断横幅会不会真的出现（`BannerVisibility`）：必须是正式授权（`.authorized`）、提醒样式不是「无」、提醒开着。临时授权一律当作不出现。
- 横幅会出现：照旧只发横幅。横幅不会出现或发送失败：走卡片，同时请 VoiceOver 念出提醒内容（`announcementRequested`，高优先级，用横幅同样的文字）；卡片不在屏幕上时，通知照样进通知中心，VoiceOver 也会念。
- 专注模式：公开接口里只有 `INFocusStatusCenter` 能读专注状态，它需要用户另外授权一次（`NSFocusStatusUsageDescription` + `requestAuthorization`），而且只说"开着某个专注模式"，不说 VibeBuddy 在不在允许名单里。为这一种情况多弹一个权限窗口不值得，所以**不检测专注模式**。已有的缓解：审批类提醒是 time-sensitive，用户允许时能穿过专注模式。
- 顺手：`GlanceView.swift` 里按钮对比度注释 2.5:1 改为实测的 2.06:1。

## 验证

- `swift test`（`AttentionRoutingTests`、`NotificationCoordinatorTests`、`NotificationDeliveryTests`，27 项）全过。
- 回归测试在路由这一层：VoiceOver 开 + 横幅不会出现 → 念出 + 卡片 + 声音，不发横幅；VoiceOver 开 + 横幅会出现 → 只发横幅；VoiceOver 开 + 横幅不会出现 + 刘海隐藏 → 念出 + 进通知中心。把路由临时改回旧逻辑，两条相关测试失败。
- `BannerVisibility` 覆盖：正式授权 + 横幅/提醒样式 → 出现；样式「无」、提醒关、临时授权、拒绝 → 不出现。
- Mac App（Debug）编译通过，改动的文件没有新警告。

## 没验证的

- 真机上开 VoiceOver 听这几种情况（要改系统的辅助功能设置和本 App 的通知样式）。特别是：菜单栏 App 在后台时，VoiceOver 会不会念 `announcementRequested`——Apple 没有写明，代码里别处（`SessionReaderPane`）用的是前台窗口的念出。下次有人用 VoiceOver 时顺带听一下。
