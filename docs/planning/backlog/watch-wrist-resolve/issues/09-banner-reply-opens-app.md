# 09: 手表横幅「回复」直接打开 App，不收文字

**What to build:** 让手表横幅上的「回复」要么真能口述，要么如实改成「打开回答」。定方案前先查 Apple 文档和同类 App：watchOS 上带 `.foreground` 的 `UNTextInputNotificationAction`，在镜像通知里会不会先弹输入框。

**Status:** ready-for-human（方案已定并实现；剩真机：点横幅「回复」，诊断记为 `notification.action-reply-card.*`，卡片上直接答）

## 为什么

2026-09-24 腕上验收（watchOS 27，Series 10，开发版 1.3.28 (58)）：三次点横幅「回复」（11:26、11:28、11:29），推送后 5–10 s 手表诊断都记为 `notification.action-opens`（回答动作，但 `userText` 为空，所以按 `.open` 处理），看到的是 App 自己的卡片（Yes / No / 口述），没有系统输入框。结果什么都没发出去，是安全的。但 WR-07 / ADR-0033 决定 5 的「横幅口述」路径在这块表上走不到，WR-07 票里 owner 步骤的第 1–4 步都依赖横幅口述，全都走不到。排查时先分清 `userText` 是 nil（响应根本不是 `UNTextInputNotificationResponse`）还是空字符串。

## 待定

- 手机的类别和手表共用：`.foreground` 是 ADR-0033 为了让点击在手表上执行而加的，去掉它会把点击送回口袋里的手机。
- 可能的方向：按钮改名、卡片打开后直接进入口述、或按平台分别注册类别。需要对照 Apple 文档实测后再选。

## 决定（2026-09-25）

**手表上的「回复」就是「打开回答卡片」。** 不再追求横幅口述，也不改手机的类别。

依据：
- Apple 文档说 watchOS 支持 `UNTextInputNotificationAction`，由系统弹输入界面（[UNTextInputNotificationAction](https://developer.apple.com/documentation/usernotifications/untextinputnotificationaction)），但没有一处说明镜像到手表的**前台**文字动作会怎样。我们在 watchOS 27 真机上三次看到的是：直接打开 App，没有输入界面，代理收到的回复里没有文字（当时没分清是 nil 还是空字符串）。iPhone 和手表注册的是同一套类别（ADR-0033 决定 4），所以也分不出按钮是哪一边画的。
- Home Assistant 遇到的是一个相关但表现不同的问题（[home-assistant/iOS#5778](https://github.com/home-assistant/iOS/pull/5778)，社区帖 [315206](https://community.home-assistant.io/t/apple-watch-actionable-notifications-speech-to-text-textinput-not-working/315206)）：他们那边输入界面弹出来了，但代理从没被调用，按钮是按每条通知动态设置的；我们这边代理被调用了，但没有输入界面，用的是固定的前台类别。我们的 `suggestionsForResponseToAction` 返回空数组，这个绕法本来就是从他们那里学的，在 watchOS 27 上没用。
- 卡片这条路已经在真机上跑通过：11:30 那次，点开通知进卡片 → 选「Yes」→ 双指互点两下发送，agent 收到了。卡片上有 agent 给的选项，也有「口述回答」（`TextFieldLink`）；多段问题逐题回答；只读问题的通知本来就不带「回复」按钮。

不采用的方案：
- **把「回复」改成后台文字动作**：后台动作在 iPhone 上执行（Apple 文档写明），手机锁在口袋里时，失败了手表上看不到。ADR-0033 就是为此把全部动作改成前台的；而且这条路要再做一轮真机验证才能知道行不行。
- **Home Assistant 的做法：在长看界面上自己画一个文字按钮**，用系统文字输入收集，再走自己的发送路径。这能省掉进卡片那一下，但长看界面背后没有 store 和中继状态，发送要另做一条 WCSession 路径和失败提示；Home Assistant 自己也没有配对真机的证据。改动太大，而卡片这条路已经能用。
- **手表单独注册一个不带文字的「回答」按钮**：Apple 只说要在通知的目标设备（iPhone）上注册类别，手表单独注册能不能改掉镜像通知的按钮，没有文档；就算生效，结果也还是打开卡片。
- **在横幅上直接放选项按钮**：每条通知的选项不同，要按通知动态设置动作（运行时重注册类别，或用长看界面的 `notificationActions`），推送负载里还要带上选项，改动超出本票。

实现：`WatchNotificationResponseRoute.resolve` 本来就把不带文字的「回复」当作打开处理（有测试）。这次让诊断把它单独记为 `notification.action-reply-card.no-text-response`（系统没给文字响应）或 `.empty-text`（给了但为空），不记录内容；下一轮真机能看出走的是这条路，也顺带回答 nil 还是空字符串。WR-07 按 `questionId` 绑定的代码保留：如果以后哪个 watchOS 把文字带过来，它照样生效。手机上照旧画文字输入框（这一轮没有复验）。ADR-0033 已补修订。

## Comments

- 2026-09-25：依据与决定见上。卡片上多点一下的问题见 11（用系统动作时没法省：长看界面上的「回复」本身就是进卡片的那一下；Home Assistant 那种自画按钮能省，但没采用，理由见上）。
- 2026-09-25 评审（Opus，MERGE WITH FIXES）：诊断分开 nil / 空字符串；Home Assistant 改为「相关但不同」并补上他们的做法；改掉「类别是固定的」；手机内联回复标为未复验；同步票 07 与 README。
