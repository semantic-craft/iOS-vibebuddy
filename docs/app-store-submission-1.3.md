# VibeBuddy 1.3 — App Store 提交文案包

截图素材已另备：[三端截图与上传清单](app-store-screenshots/1.3/README.md)。含中英文环境原生实拍；中文未翻译标签及未收录的实际表盘组件见素材清单。

状态（2026-09-06 22:18）：移动版 **1.3（10）** 提交后被 Apple 自动校验退回，邮件明确为 **ITMS-90455**：Watch 包的 `MinimumOSVersion=26.6` 不受支持。已将 Watch 宿主与扩展的最低版本改为 **26.5**，四个移动目标统一升至 **1.3（11）**，已于 22:18 重新提交，Apple 当前为 **Waiting for Review**。Submission ID：`447e220d-5bcb-4344-9335-051f0ee2e891`。Mac **1.3（7）** 已公开在 [GitHub v1.3](https://github.com/semantic-craft/iOS-vibebuddy/releases/tag/v1.3)。商店 8 张中英文截图来自构建 10；构建 11 只调整系统版本要求及构建号，界面与功能一致，继续使用该组截图。半小时真实体验未在本轮补做；提交审核不代表验收、获批或公开上架。

本包是本次商店描述、更新日志和审核说明的入口；旧 `app-store-paste-sheet.md` 是 1.1 历史材料。以下保留文案来源；在线提交已补充公开包不含 APNs 凭据及相关能力边界。下载引导 Ticket 位于 `.scratch/mac-companion-download/issues/01-guide-mac-companion-download.md`，已完成本地实现和模拟器检查，真实配对验收尚待完成。

## 阅读与使用顺序

- **审核员说明**：第 6 节，按“用途与依赖 → 演示 → 真实功能 → 权限与数据”阅读。仅此节用于 App Review Notes。
- **面向用户**：第 2–5 节分别用于 Description 与 What's New；不将内部验收记录混入商店字段。
- **提交负责人**：第 7 节保留内部验收事项；已提交状态不等于全部实际体验通过。

## 1. 定位与搜索字段

核心信息前置：AI 编程任务监控 → 批准与回应 → Codex / Claude Code → 手表 → Mac 伴侣下载。描述首段优先帮助新用户理解用途；搜索曝光同时依赖名称、副标题和关键词，不承诺仅凭描述排序就提升排名。关键词避免无关品牌和重复名称，第三方产品只在介绍实际兼容能力时使用，不暗示官方关系。

| 字段 | 简体中文 | English (US) |
|---|---|---|
| 名称（沿用现有） | VibeBuddy: Agent Monitor | VibeBuddy: Agent Monitor |
| 副标题 | AI 编程任务进度、提醒与远程批准 | AI coding status and approvals |
| 主分类 / 次分类 | Developer Tools / Utilities | Developer Tools / Utilities |
| 关键词 | 编程,任务,进度,批准,提醒,手表,额度,开发,终端 | coding,developer,terminal,approval,notification,watch,quota,workflow,progress |

关键词按 UTF-8 字节检查，均少于 100 字节。名称、副标题各不超过 30 字符，推广文本不超过 170 字符；描述与更新日志各不超过 4,000 字符。

### 中文推广文本（可粘贴）

离开电脑，也能掌握 AI 编程进度。Codex 深度集成、全新 Apple Watch 表盘小组件，以及焕新的图标与 Mac 界面，让任务状态从桌面延伸到口袋和手腕。搭配免费的 Mac 版伴侣使用。

### English promotional text（可粘贴）

Step away, stay in the loop. Deeper Codex integration, new Watch complications and refreshed Mac UI bring your coding tasks closer. Free Mac companion required.

## 2. App Store 中文介绍（可粘贴）

在 iPhone 上查看 Claude Code 与 Codex 的 AI 编程任务进度，接收需要回应的提醒，并处理支持的权限批准与提问。VibeBuddy 帮你随时看清：哪些任务正在运行、哪些需要你、哪些已经完成。

真实任务数据来自你自己的 Mac。需安装免费的 Mac 版伴侣并扫码配对，保持 Mac 运行且可连接。无需 VibeBuddy 账号；没有 Mac 时可先体验内置演示。

看进度，一眼就懂
任务按“需要回应、进行中、已完成”整理，显示项目与可用的模型、上下文信息。优先看到等待你的任务，更容易决定下一步。

Codex 深度集成
连接 Mac 上的 Codex Desktop 与 CLI 任务，查看进度；在支持的连接中回答提问、追加指令或发起新任务。也支持 Claude Code，具体操作取决于 Agent 版本、配置及请求是否允许远程处理。

在手机上处理批准与提问
先查看命令或修改预览，再选择批准或拒绝。支持的提问可直接回复；需要回到 Mac 处理的请求会明确提示。远程操作需要已配对且可连接的 Mac。

抬腕，看看任务与额度
新增 Apple Watch 表盘小组件：矩形位置显示关注任务，圆形位置查看 Claude、Codex 或两者的剩余额度。额度提供五种显示样式，可按习惯选择。需要配对的 iPhone；数值取决于来源提供的数据，刷新由系统调度。

图标、交互与 Mac 界面焕新
统一的小猫形象和 Agent 图标，让三端状态更容易辨认。手机连接菜单更简洁，Mac 菜单栏、刘海概览与任务卡片让你在桌面上也能快速掌握进度。

提醒与锁屏概览
通过通知、实时活动与灵动岛查看任务状态。提醒受连接条件、通知设置与系统调度影响；离线时需要恢复与 Mac 的连接才能操作。

可选语音伙伴
想开口交流时，可使用自己的服务商 API key 启用语音。此功能默认关闭；音频与所选会话上下文直接发送给你选择的服务商，可能产生该服务商的费用。不启用语音也能使用任务看板和批准功能。

第一次使用
1. 在 Mac 上打开下方 GitHub 下载页，在 Assets 中下载 DMG，安装免费的 Mac 版伴侣。
2. 让 iPhone 与 Mac 连接同一局域网，在 Mac 菜单栏打开“配对手机”。
3. 用 iPhone 扫码配对，按 Mac 设置中的 Setup 指引接入 Agent。

Mac 版伴侣下载：
https://github.com/semantic-craft/iOS-vibebuddy/releases/latest

需要 Apple Silicon Mac、macOS 14 或更高版本。尚未准备好 Mac？在连接页点“查看演示（无需 Mac）”，先体验示例任务。

免费、开源，无需 VibeBuddy 账号。任务连接直接通往你的 Mac；启用推送时通知经 Apple 服务发送，可选语音直连所选服务商。VibeBuddy 不运营会话云服务，不含广告或追踪。

VibeBuddy 是独立伴侣工具，与 OpenAI 或 Anthropic 无隶属关系。

## 3. App Store English description（可粘贴）

Monitor Claude Code and Codex AI coding tasks on iPhone, see what needs your attention, and handle supported approvals and questions. VibeBuddy puts three clear states in your pocket: Needs Response, Working and Done.

Live task data comes from your own Mac. Install the free Mac companion, pair by QR code, and keep your Mac running and reachable. No VibeBuddy account is required. A built-in demo is available without a Mac.

SEE WHAT NEEDS YOU
Browse tasks by status, with project details and available model and context information. Find the task waiting for you without checking every window.

DEEPER CODEX INTEGRATION
Follow Codex Desktop and CLI tasks on your Mac. Through supported connections, answer questions, send follow-up instructions or start a task. Claude Code is also supported. Available actions depend on the agent version, setup and whether a request can be handled remotely.

REVIEW, THEN RESPOND
Read a command or a bounded change preview before approving or denying it. Reply to supported questions from your phone. Requests that need the Mac say so. Remote actions require a reachable paired Mac.

YOUR TASKS, ON YOUR WRIST
New Apple Watch complications show followed tasks in a rectangular slot and remaining Claude, Codex or combined quota in a circular slot. Choose from five quota display styles. A paired iPhone is required; values depend on available source data and refresh timing is controlled by the system.

A REFRESHED COMPANION EXPERIENCE
A shared cat identity, consistent agent icons and a simpler phone connection menu make status easier to recognize. The updated Mac menu-bar interface, notch glance and task cards keep progress close at hand on your desktop too.

NOTIFICATIONS AND LOCK-SCREEN STATUS
Check task status through notifications, Live Activities and Dynamic Island. Availability depends on connectivity, notification settings and system scheduling. Reconnect to your Mac before taking action when offline.

OPTIONAL VOICE COMPANION
Use your own provider API key to enable voice conversations. Voice is off by default. Audio and selected session context go directly to your chosen provider, whose fees may apply. The dashboard and approvals work without voice.

GET STARTED WITH YOUR MAC
1. Open the GitHub download page below on your Mac. Under Assets, download the DMG and install the free Mac companion.
2. Put iPhone and Mac on the same local network, then open “Pair a phone” in the Mac menu bar.
3. Scan the QR code with iPhone and follow Setup in the Mac settings to connect your agent.

Download the Mac companion:
https://github.com/semantic-craft/iOS-vibebuddy/releases/latest

Requires an Apple Silicon Mac with macOS 14 or later. Just exploring? Tap “See the demo (no Mac needed)” on the connection screen to try sample tasks.

Free and open source. No VibeBuddy account, advertising or tracking. Task connections go directly to your Mac. When enabled, notifications use Apple's push service; optional voice connects to your selected provider. VibeBuddy operates no session cloud service.

VibeBuddy is an independent companion and is not affiliated with OpenAI or Anthropic.

## 4. 中文更新日志（可粘贴）

本次升级重点：Codex 集成、Apple Watch 表盘小组件，以及 iPhone 与 Mac 界面更新。相比初版的任务状态看板，现在可在支持的连接中处理更多任务回应。

• Agent 适配升级：完善 Claude Code 与 Codex 的任务状态、权限请求及提问处理，让你更容易知道下一步该做什么。
• Codex 深度集成：支持 Desktop 与 CLI 任务观测，并在支持的连接中回答提问、追加指令和发起任务。
• 新增手表表盘小组件：抬腕查看关注任务；圆形额度组件支持 Claude、Codex 或两者，提供五种显示样式。
• 图标与交互焕新：统一三端小猫形象与 Agent 图标，简化手机连接菜单，让任务状态更清楚。
• macOS UI 更新：菜单栏、刘海概览与任务卡片相互配合，改善窗口重新打开和概览位置恢复。
• 提醒与连接体验改进：新增额度提醒控制和漏接等待统计，完善请求操作与连接恢复。

请同步更新免费的 Mac 版伴侣，以使用本次升级功能。在 Mac 打开：
https://github.com/semantic-craft/iOS-vibebuddy/releases/latest

Apple Watch 需要配对的 iPhone；远程操作需要可连接的 Mac。Agent 操作与额度数据依各自支持情况提供。

## 5. English What's New（可粘贴）

This update adds deeper Codex integration, Apple Watch complications, and refreshed iPhone and Mac interfaces. Compared with the original status dashboard, supported connections now offer more ways to respond to tasks.

• Updated agent integrations: improved task status, permission requests and question handling for Claude Code and Codex.
• Deeper Codex integration: follow Desktop and CLI tasks, with questions, follow-up instructions and new tasks through supported connections.
• New Watch complications: glance at followed tasks or remaining Claude, Codex or combined quota, with five quota display styles.
• Refreshed icons and interactions: a shared cat identity, consistent agent icons and a simpler phone connection menu.
• Updated macOS UI: menu-bar status, notch glance and task cards, plus improved window reopening and glance position recovery.
• Better notification and connection controls: quota preferences, missed-wait tracking, request actions and connection recovery improvements.

Update the free Mac companion to use the new features. Open on your Mac:
https://github.com/semantic-craft/iOS-vibebuddy/releases/latest

Apple Watch requires a paired iPhone. Remote actions require a reachable Mac. Agent actions and quota data depend on source support.

## 6. App Review Information（文案来源）

### Purpose and requirements

VibeBuddy helps developers monitor Claude Code and Codex tasks on their own Mac and respond to supported requests from iPhone. Apple Watch receives task and quota information through its paired iPhone.

No VibeBuddy login is required. Live tasks require the free Mac companion, an Apple Silicon Mac with macOS 14 or later, and a configured supported agent. The GitHub link downloads macOS companion software; it is not an iOS installer or a purchase flow. Demo mode requires neither a Mac nor an API key.

### Start with the demo

1. On the iPhone connection screen, tap “See the demo (no Mac needed).”
2. Open a task that needs a response. Inspect its request, then use a sample approval or reply action. These actions change sample data only; no command is executed on a Mac.
3. Keep iPhone open in Demo mode and open VibeBuddy on its paired Apple Watch. Watch receives the sample state from iPhone and has no separate Demo button.

Demo mode demonstrates the interface, not live agent connectivity, push delivery, or voice calls.

### Review live tasks

1. On the Mac, download and install the companion from:
https://github.com/semantic-craft/iOS-vibebuddy/releases/latest
2. Open Setup in the Mac app to connect an installed agent. In the Mac menu bar, open “Pair a phone.”
3. Connect iPhone and Mac to the same local network. Tap “Scan to pair” on iPhone and scan the Mac QR code. Keep the Mac app running.
4. Start a task in the configured agent on Mac. Its state appears on iPhone. Open a supported approval or question, review it, and respond. The response goes to the paired Mac; requests without remote actions must be handled on Mac. Supported Codex connections also accept follow-up instructions and new tasks from iPhone.
5. On Apple Watch, add “Followed tasks” to a supported rectangular complication slot or “Quota” to a circular slot. Quota requires available agent account data; an unavailable value is not a fresh balance. Refresh timing is controlled by watchOS.

If the Mac cannot be reached, check that the companion is running, both devices share a local network, and Local Network access is allowed. The download guide remains available under Settings → “Download or update the Mac app.”

### Permissions and data

- Camera: scans the Mac pairing QR code. Manual address entry is also available.
- Local Network: connects iPhone to the user's Mac for task data and supported responses.
- Notifications: optional task alerts. Delivery depends on connectivity, user settings, and the system; Demo does not verify push delivery.
- Microphone: optional voice only, off by default. The user selects a provider, supplies an API key, accepts the disclosure, grants microphone access, and explicitly starts a conversation. Audio and selected task context go directly to that provider. Core monitoring and approvals do not need a voice key. Provider fees may apply.

Task data is sourced from the user's Mac; this does not mean all app traffic stays local. Enabled push uses Apple services and optional voice uses the selected provider. VibeBuddy has no cloud account, advertising, or tracking. It is independent of OpenAI and Anthropic.

## 7. 提交前补齐（内部，不粘贴）

**当前不可直接提交审核。** 以下是实际交付缺口，不是靠文案解释即可消除的问题。完成后在最终 Notes 中补充已验证的 Mac 成品版本、Agent 版本、附件名称和可复现结果；不要留下占位符，也不要声称附件已经提供。

| 审核员需要判断 | 我们应准备的证据 | 当前处理 |
|---|---|---|
| 是否能体验完整功能 | 最终 iPhone build、匹配的公开 Mac DMG、可重复的配对及任务回应步骤 | 待成品真机验收；不能要求审核员从源码构建 |
| 特殊环境如何复现 | 真机录屏：首次启动 → Mac 配对 → 真实任务 → 请求回应；标明设备、系统、Mac 与 Agent 版本 | 待录制。演示和录屏均不自动替代 Apple 要求的完整访问；必要时协调硬件或额外审核资源 |
| 语音是否可测试 | 最终支持的服务商、有效且适用于审核的访问安排、启动与停止步骤 | 待确定安全的审核访问安排，不能假定审核员自备付费账号/API key；不得把生产密钥写入仓库或公开文档 |
| 通知是否实际可用 | 公众成品推送路径及真机结果，说明前台/后台实际支持范围 | 见下方 ADR-0013 缺口，不以开发者自用结果替代 |
| 数据说明是否一致 | App 内披露、权限说明、公开隐私政策与 App Privacy 答案逐项相符 | 待按最终数据流复核；“开发者不接收数据”不自动等于问卷全部选择不收集 |
| 宣传是否对应成品 | 各平台最终截图、Watch 实际表盘展示、逐项核实的 What's New | 现有截图为候选素材；Mac 图仅作伴侣说明/附件，不放入 iPhone 截图栏 |

联系信息填写 App Store Connect 的 App Review Information 专用字段。审核备注使用短标题、按钮原名和“操作 → 预期结果”；不向审核员宣称“完全合规”或要求其据此免除测试。


- 完成最终成品与对应 Mac 公开包验收，确认下载页实际提供新版 DMG。2026-09-06 核对时 latest 指向 v1.1；不能用旧包替代新版审核依赖。
- 当前 1.3 验收记录仍有 Watch 表盘、额度样式及连续实际体验待验；以最终成品重新核对上述功能与演示步骤。不要写“完美兼容”“支持所有最新 Agent”“通知绝不漏接”或“表盘实时秒更”。
- 根据 ADR-0013 完成公众 App Store 成品的推送交付决定及验证；目前仅有 owner-controlled 路径，不能告诉普通 App Store 用户自备其他 Team 的 key 就能解决。最终审核说明需补充已验收成品的通知配置步骤与可复现范围，不提交未实现的后台通知承诺。
- 准备对应最终成品的中英文 iPhone、Watch 截图，以及真实 Mac 配对和请求回应录屏。演示截图应如实标明示例数据；旧 1.1 截图和录屏不自动作为新版证据。
- 下载引导已本地实现；发布前仍需走通首次安装 → 下载 → 真机配对 → 真实任务流程，再加入本次 What's New。
- 沿用并核对现有 Support URL、Marketing URL 与公开隐私政策 URL；隐私政策正文以 `docs/privacy-policy.md` 为准，按最终数据流填写 App Privacy。本包不沿用旧材料中未经本次核对的隐私问卷结论。
- 最终选择已验收 build，核对在线 metadata，再提交；文案准备不等于 App Store 提交。

## 8. 来源与措辞依据

- 初版对比：Git 标签 `v1.0` 的 README（状态看板、本地提醒，Codex adapter 与 Dynamic Island 当时列为后续工作）；当前 `CONTEXT.md`、`docs/release-notes-1.1.md`、`docs/release-notes-1.2.md`、`docs/release-notes-1.3.md`。
- 演示入口：`VibeBuddyApp/Sources/ConnectView.swift`；Watch 组件：`VibeBuddyApp/WatchWidget/FollowedTaskWidget.swift`。设备验收记录在 `.scratch/release-1.3/ACCEPTANCE.md`，不把安装或构建成功当作完成验收。
- Apple 字段长度与关键词限制：[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)。名称/副标题与搜索字段策略：[Creating your product page](https://developer.apple.com/app-store/product-page/)。
- 伴侣环境的审核材料：[App Review](https://developer.apple.com/app-store/review/)；准确 metadata 与可复现审核要求：[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。以上于 2026-09-06 核对。

## 9. 审核依据与编辑原则（内部）

2026-09-06 核对 Apple 官方 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)（Before You Submit、2.1、2.3、5.1）及 [App Review](https://developer.apple.com/app-store/review/)。重点是完整访问、可复现的特殊环境、准确元数据与明确数据用途。这里采用短标题、编号步骤和明确预期结果，是为减少阅读负担所作的编辑选择，并非 Apple 规定的固定模板或对审核员个人审美的推断。

审核说明不复述市场口号，不使用“完美兼容”“所有最新 Agent”“保证送达”“全部数据不离设备”等无法由当前成品支持的绝对表述。新功能须对应审核路径；演示、真机录屏、构建成功、审核通过分别陈述。

## 本次在线提交补充

- 中英文描述及审核 Notes 明示：公开 Mac 下载不包含项目 APNs 凭据；关闭 App 后的远程推送不是开箱即用功能，需 App 签名团队授权的提供者。没有运营中的 VibeBuddy 云服务。
- 审核 Notes 明示 Mac 1.3（7）下载、移动 1.3（11）、演示与真实功能的区别，以及 Watch 配置页冷启动首次可能占位、重新打开显示图标的限制。
- 审核联系人已按用户本轮提供内容填写；个人电话和邮箱不写入仓库。
- 当前设备仍为移动 1.3（9）；本次未用送审包替换设备安装。
- App Store 设置为审核通过后自动发布；构建 10 因 ITMS-90455 被退回，修正后的构建 11 已于 22:18 重新提交，当前 Waiting for Review。
